# Desktop → tinty auto-sync plugin (ZLE-safe, debounced, race-free)
# Supports Linux (XDG Desktop Portal) and macOS (DistributedNotificationCenter)
#
# Architecture:
# - One shell instance runs the watcher (detects OS theme changes)
# - Watcher signals all shells via USR1 when theme changes
# - Each shell runs `tinty apply` for itself (terminal-agnostic)

# Debug logging
_tinty_debug() {
  echo "[$(date '+%H:%M:%S')] $*" >> /tmp/tinty-debug.log
}

# Only run in interactive shells with a terminal
if [[ ! -t 0 || -z "$TERM" || "$TERM" == "dumb" ]]; then
  _tinty_debug "SKIP: not interactive (tty=$([[ -t 0 ]] && echo yes || echo no), TERM=$TERM)"
  return
fi

_tinty_debug "START: OSTYPE=$OSTYPE, TERM=$TERM, PID=$$"

# Safe initialization once ZLE is active & PATH is ready
autoload -Uz add-zle-hook-widget

# Helper: get theme name for color-scheme value (0=light, 1=dark, 2=light)
_tinty_theme_for_scheme() {
  [[ "$1" == "1" ]] && echo "$ZSH_TINTY_DARK" || echo "$ZSH_TINTY_LIGHT"
}

# Get current color scheme (cross-platform)
_tinty_get_current_scheme() {
  if [[ "$OSTYPE" == darwin* ]]; then
    # macOS: Dark returns "Dark", Light returns error/empty
    [[ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" == "Dark" ]] && echo 1 || echo 0
  else
    # Linux: Query XDG Desktop Portal
    dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop \
      /org/freedesktop/portal/desktop \
      org.freedesktop.portal.Settings.Read \
      string:'org.freedesktop.appearance' \
      string:'color-scheme' 2>/dev/null | \
      grep -oP 'uint32 \K\d+' | head -1
  fi
}

# Apply theme to THIS shell's terminal
_tinty_apply_current_scheme() {
  local scheme=$(_tinty_get_current_scheme)
  local theme=$(_tinty_theme_for_scheme "$scheme")
  _tinty_debug "APPLY: scheme=$scheme, theme=$theme"
  $TINTY_BIN apply "$theme" 2>/dev/null
}

# Signal handler: apply theme when notified
TRAPUSR1() {
  _tinty_debug "SIGUSR1: received, applying theme"
  _tinty_apply_current_scheme
}

# Signal all registered shells to apply theme
_tinty_signal_all_shells() {
  _tinty_debug "SIGNAL: broadcasting to all shells"
  local pidfile
  for pidfile in /tmp/tinty-shells/*(N); do
    local pid=$(cat "$pidfile" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      _tinty_debug "SIGNAL: sending USR1 to $pid"
      kill -USR1 "$pid" 2>/dev/null
    else
      _tinty_debug "SIGNAL: removing stale $pidfile"
      rm -f "$pidfile"
    fi
  done
}

tinty_portal_zle_init() {
  _tinty_debug "ZLE_INIT: called"

  # Prevent duplicates - only run once per shell session
  if [[ -n "$TINTY_PORTAL_INITIALIZED" ]]; then
    _tinty_debug "ZLE_INIT: already initialized, skip"
    return 0
  fi
  export TINTY_PORTAL_INITIALIZED=1

  add-zle-hook-widget -d zle-line-init tinty_portal_zle_init
  setopt LOCAL_OPTIONS NO_NOTIFY NO_MONITOR

  # Resolve binaries
  export TINTY_BIN=$(command -v tinty)
  if [[ -z "$TINTY_BIN" ]]; then
    _tinty_debug "ZLE_INIT: tinty not found, abort"
    return 0
  fi
  _tinty_debug "ZLE_INIT: TINTY_BIN=$TINTY_BIN"

  # Platform-specific watcher binary
  local WATCHER_BIN
  if [[ "$OSTYPE" == darwin* ]]; then
    WATCHER_BIN=$(command -v macwatch)
    if [[ -z "$WATCHER_BIN" ]]; then
      _tinty_debug "ZLE_INIT: macwatch not found, abort"
      return 0
    fi
  else
    WATCHER_BIN=$(command -v dbus-monitor)
    if [[ -z "$WATCHER_BIN" ]]; then
      _tinty_debug "ZLE_INIT: dbus-monitor not found, abort"
      return 0
    fi
  fi
  _tinty_debug "ZLE_INIT: WATCHER_BIN=$WATCHER_BIN"

  # User-overridable theme names
  export ZSH_TINTY_LIGHT="${ZSH_TINTY_LIGHT:-base16-ia-light}"
  export ZSH_TINTY_DARK="${ZSH_TINTY_DARK:-base16-ia-dark}"

  # Register this shell for signaling (use PID as key for simplicity)
  mkdir -p /tmp/tinty-shells
  echo $$ > "/tmp/tinty-shells/$$"
  _tinty_debug "ZLE_INIT: registered shell PID $$ in /tmp/tinty-shells/$$"

  # Cleanup on shell exit
  _tinty_cleanup() {
    if [[ $ZSH_SUBSHELL -eq 0 ]]; then
      rm -f "/tmp/tinty-shells/$$"
      [[ -n "$TINTY_WATCHER_PID" ]] && kill "$TINTY_WATCHER_PID" 2>/dev/null
    fi
  }
  add-zsh-hook zshexit _tinty_cleanup

  # Apply initial theme
  _tinty_debug "ZLE_INIT: applying initial theme"
  _tinty_apply_current_scheme

  # Try to become the watcher (only one shell runs this)
  _tinty_debug "ZLE_INIT: attempting to become watcher..."
  if mkdir /tmp/tinty-watcher.lock 2>/dev/null; then
    _tinty_debug "ZLE_INIT: acquired watcher lock, starting watcher"

    # Platform-specific watcher
    if [[ "$OSTYPE" == darwin* ]]; then
      {
        _tinty_debug "WATCHER: macOS watcher starting"
        local last_scheme=""
        "$WATCHER_BIN" --include AppleInterfaceThemeChangedNotification 2>&1 |
        while read -r line; do
          _tinty_debug "WATCHER: received notification"
          sleep 0.2  # Debounce
          local scheme=$(_tinty_get_current_scheme)
          if [[ -n "$scheme" && "$scheme" != "$last_scheme" ]]; then
            last_scheme="$scheme"
            _tinty_debug "WATCHER: scheme changed to $scheme, signaling shells"
            _tinty_signal_all_shells
          fi
        done
        # Watcher exited - release lock
        rmdir /tmp/tinty-watcher.lock 2>/dev/null
        _tinty_debug "WATCHER: exited, released lock"
      } &
    else
      {
        _tinty_debug "WATCHER: Linux watcher starting"
        local last_scheme=""
        "$WATCHER_BIN" --session "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='org.freedesktop.appearance',arg1='color-scheme'" 2>&1 |
        while read -r line; do
          sleep 0.2  # Debounce
          local scheme=$(_tinty_get_current_scheme)
          if [[ -n "$scheme" && "$scheme" != "$last_scheme" ]]; then
            last_scheme="$scheme"
            _tinty_signal_all_shells
          fi
        done
        rmdir /tmp/tinty-watcher.lock 2>/dev/null
      } &
    fi

    TINTY_WATCHER_PID=$!
    _tinty_debug "ZLE_INIT: watcher started with PID=$TINTY_WATCHER_PID"
    disown
  else
    _tinty_debug "ZLE_INIT: another shell is the watcher, will receive signals"
  fi
}

# Run watcher only after ZLE has fully initialized (cursor is set, prompt ready)
add-zle-hook-widget zle-line-init tinty_portal_zle_init
