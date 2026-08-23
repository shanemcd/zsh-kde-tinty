# Desktop → tinty auto-sync plugin (ZLE-safe, debounced, race-free)
# Supports Linux (XDG Desktop Portal) and macOS (DistributedNotificationCenter)
#
# Architecture:
# - One shell instance runs the watcher (detects OS theme changes)
# - Linux: watcher signals all shells via USR1; each shell runs `tinty apply`
# - macOS: watcher runs `tinty apply` once (Ghostty/iTerm hooks update all windows)

# Debug logging
_tinty_debug() {
  echo "[$(date '+%H:%M:%S')] $*" >> /tmp/tinty-debug.log
}

# Only run in interactive shells with a terminal
if [[ ! -t 0 || -z "$TERM" || "$TERM" == "dumb" ]]; then
  _tinty_debug "SKIP: not interactive (tty=$([[ -t 0 ]] && echo yes || echo no), TERM=$TERM)"
  return
fi

_tinty_debug "START: OSTYPE=$OSTYPE, TERM=$TERM, TERM_PROGRAM=${TERM_PROGRAM:-}, PID=$$"

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

# Run tinty apply. On Linux, also write any OSC output to this shell's TTY.
# On macOS, tinty hooks (Ghostty SIGUSR2 / iTerm AppleScript) update terminals
# without needing stdout, so we only need to invoke tinty once.
# A short-lived mkdir mutex (with stale-owner reaping) serializes applies so
# multiple watchers/tabs can never clobber each other with different themes.
_tinty_acquire_apply_lock() {
  local lock=/tmp/tinty-apply.lock
  for _ in 1 2 3 4 5; do
    if mkdir "$lock" 2>/dev/null; then
      echo $$ > "$lock/pid"
      return 0
    fi
    # Reap stale owner (dead pid) before giving up
    local owner=$(cat "$lock/pid" 2>/dev/null || echo 0)
    if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$lock" 2>/dev/null
      continue
    fi
    sleep 0.2
  done
  return 1
}
_tinty_release_apply_lock() {
  rm -f /tmp/tinty-apply.lock/pid 2>/dev/null
  rmdir /tmp/tinty-apply.lock 2>/dev/null
}
_tinty_apply_theme() {
  local theme=$1
  _tinty_debug "APPLY: theme=$theme tty=${TTY:-none} term_program=${TERM_PROGRAM:-}"

  # Only one apply in flight at a time (across all tabs/watchers).
  _tinty_acquire_apply_lock || { _tinty_debug "APPLY: skipped (another apply in progress)"; return 0; }

  if [[ "$OSTYPE" == darwin* ]]; then
    $TINTY_BIN apply "$theme" >/dev/null 2>&1
  else
    local output=$($TINTY_BIN apply "$theme" 2>/dev/null)
    if [[ -n "$output" && -n "$TTY" && -w "$TTY" ]]; then
      printf '%s' "$output" > "$TTY"
    fi
  fi

  _tinty_release_apply_lock
}

_tinty_apply_current_scheme() {
  local scheme=$(_tinty_get_current_scheme)
  [[ -z "$scheme" ]] && return 1
  _tinty_apply_theme "$(_tinty_theme_for_scheme "$scheme")"
}

# Linux: each shell applies when signaled
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

_tinty_acquire_watcher_lock() {
  local lock=/tmp/tinty-watcher.lock
  for _ in 1 2 3; do
    if mkdir "$lock" 2>/dev/null; then
      echo $$ > "$lock/pid"  # This shell is the watcher
      return 0
    fi
    # Lock held — only steal it if the recorded owner PID is dead.
    # (Never treat a live, long-running watcher as "stale" by age, which is
    # what allowed new tabs to spawn a second macwatch.)
    local owner=$(cat "$lock/pid" 2>/dev/null || echo 0)
    if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
      _tinty_debug "ZLE_INIT: reaping dead watcher owner ($owner)"
      rm -rf "$lock" 2>/dev/null
      continue
    fi
    return 1  # A live watcher owns the lock
  done
  return 1
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

  # Register this shell (used on Linux for USR1 fan-out)
  mkdir -p /tmp/tinty-shells
  echo $$ > "/tmp/tinty-shells/$$"
  _tinty_debug "ZLE_INIT: registered shell PID $$ in /tmp/tinty-shells/$$"

  # Cleanup on shell exit
  _tinty_cleanup() {
    if [[ $ZSH_SUBSHELL -eq 0 ]]; then
      rm -f "/tmp/tinty-shells/$$"
      if [[ -n "$TINTY_WATCHER_PID" ]]; then
        kill "$TINTY_WATCHER_PID" 2>/dev/null
        rm -rf /tmp/tinty-watcher.lock 2>/dev/null
      fi
    fi
  }
  add-zsh-hook zshexit _tinty_cleanup

  # Apply initial theme
  _tinty_debug "ZLE_INIT: applying initial theme"
  _tinty_apply_current_scheme

  # Start platform-specific watcher (single instance across shells)
  if ! _tinty_acquire_watcher_lock; then
    _tinty_debug "ZLE_INIT: another shell is the watcher"
    return 0
  fi

  _tinty_debug "ZLE_INIT: acquired watcher lock, starting watcher"
  if [[ "$OSTYPE" == darwin* ]]; then
    # macOS: one watcher runs tinty apply (hooks update all Ghostty/iTerm windows)
    {
      _tinty_debug "WATCHER: macOS watcher starting"
      local last_scheme=$(_tinty_get_current_scheme)
      _tinty_debug "WATCHER: initial scheme=$last_scheme"
      "$WATCHER_BIN" --include AppleInterfaceThemeChangedNotification 2>&1 |
      while read -r line; do
        _tinty_debug "WATCHER: received notification"
        sleep 0.2  # Debounce
        local scheme=$(_tinty_get_current_scheme)
        if [[ -n "$scheme" && "$scheme" != "$last_scheme" ]]; then
          last_scheme="$scheme"
          local theme=$(_tinty_theme_for_scheme "$scheme")
          _tinty_debug "WATCHER: scheme changed to $scheme, applying $theme"
          _tinty_apply_theme "$theme"
        fi
      done
      rm -rf /tmp/tinty-watcher.lock 2>/dev/null
      _tinty_debug "WATCHER: exited, released lock"
    } &
  else
    # Linux: one watcher signals all shells to apply locally
    {
      _tinty_debug "WATCHER: Linux watcher starting"
      local last_scheme=$(_tinty_get_current_scheme)
      _tinty_debug "WATCHER: initial scheme=$last_scheme"
      "$WATCHER_BIN" --session "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='org.freedesktop.appearance',arg1='color-scheme'" 2>&1 |
      while read -r line; do
        sleep 0.2  # Debounce
        local scheme=$(_tinty_get_current_scheme)
        if [[ -n "$scheme" && "$scheme" != "$last_scheme" ]]; then
          last_scheme="$scheme"
          _tinty_debug "WATCHER: scheme changed to $scheme, signaling shells"
          _tinty_signal_all_shells
        fi
      done
      rm -rf /tmp/tinty-watcher.lock 2>/dev/null
      _tinty_debug "WATCHER: exited, released lock"
    } &
  fi

  TINTY_WATCHER_PID=$!
  _tinty_debug "ZLE_INIT: watcher started with PID=$TINTY_WATCHER_PID"
  disown
}

# Run watcher only after ZLE has fully initialized (cursor is set, prompt ready)
add-zle-hook-widget zle-line-init tinty_portal_zle_init
