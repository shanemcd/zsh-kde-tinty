# Desktop → tinty auto-sync plugin (ZLE-safe, debounced, race-free)
# Uses freedesktop.org XDG Desktop Portal for cross-desktop compatibility

# Only run in interactive shells with a terminal
if [[ ! -t 0 || -z "$TERM" || "$TERM" == "dumb" ]]; then
  return
fi

# Safe initialization once ZLE is active & PATH is ready
autoload -Uz add-zle-hook-widget

# Helper: get theme name for color-scheme value (0=light, 1=dark, 2=light)
_tinty_theme_for_scheme() {
  [[ "$1" == "1" ]] && echo "$ZSH_TINTY_DARK" || echo "$ZSH_TINTY_LIGHT"
}

# Apply theme to all registered shells
_tinty_apply_for_scheme() {
  local color_scheme=$1

  {
    flock -n 9 || exit 0  # If another tab is applying, skip

    # Get tinty output once
    local theme=$(_tinty_theme_for_scheme "$color_scheme")
    local tinty_output=$($TINTY_BIN apply "$theme" 2>/dev/null)

    # Broadcast to all registered shells
    [[ -d /tmp/tinty-shells ]] || exit 0
    for pts_file in /tmp/tinty-shells/*; do
      [[ -e "$pts_file" ]] || continue

      local pts="/dev/pts/$(basename "$pts_file")"
      local pid=$(cat "$pts_file" 2>/dev/null)

      # Verify shell is running and terminal is writable
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ -w "$pts" ]]; then
        printf '%s' "$tinty_output" > "$pts" 2>/dev/null
      else
        rm -f "$pts_file"  # Clean up stale registration
      fi
    done
  } 9>/tmp/tinty-portal.lock
}

# Get current color scheme from portal
_tinty_get_current_scheme() {
  dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop \
    /org/freedesktop/portal/desktop \
    org.freedesktop.portal.Settings.Read \
    string:'org.freedesktop.appearance' \
    string:'color-scheme' 2>/dev/null | \
    grep -oP 'uint32 \K\d+' | head -1
}

# Detect terminal device using ps (during zle-line-init, tty/fds aren't available yet)
_tinty_get_tty() {
  local ctty=$(ps -p $$ -o tty= 2>/dev/null | tr -d ' ')
  [[ "$ctty" =~ ^pts/[0-9]+$ ]] && echo "/dev/$ctty"
}

tinty_portal_zle_init() {
  # Prevent duplicates - only run once per shell session
  [[ -n "$TINTY_PORTAL_WATCHER_RUNNING" ]] && return 0
  export TINTY_PORTAL_WATCHER_RUNNING=1

  add-zle-hook-widget -d zle-line-init tinty_portal_zle_init
  setopt LOCAL_OPTIONS NO_NOTIFY NO_MONITOR

  # Resolve binaries and bail if missing
  export TINTY_BIN=$(command -v tinty)
  local DBUS_MONITOR=$(command -v dbus-monitor)
  [[ -z "$TINTY_BIN" || -z "$DBUS_MONITOR" ]] && return 0

  # User-overridable theme names
  export ZSH_TINTY_LIGHT="${ZSH_TINTY_LIGHT:-base16-ia-light}"
  export ZSH_TINTY_DARK="${ZSH_TINTY_DARK:-base16-ia-dark}"

  # Detect and register this terminal
  local my_tty=$(_tinty_get_tty)
  local my_pts_num=""
  [[ "$my_tty" =~ /dev/pts/([0-9]+)$ ]] && my_pts_num="${match[1]}"

  if [[ -n "$my_pts_num" ]]; then
    mkdir -p /tmp/tinty-shells
    echo $$ > "/tmp/tinty-shells/$my_pts_num"
  fi

  # Combined cleanup on shell exit (only from main shell, not subshells)
  _tinty_cleanup() {
    if [[ $ZSH_SUBSHELL -eq 0 ]]; then
      [[ -n "$my_pts_num" ]] && rm -f "/tmp/tinty-shells/$my_pts_num"
      [[ -n "$TINTY_PORTAL_WATCHER_PID" ]] && kill "$TINTY_PORTAL_WATCHER_PID" 2>/dev/null
    fi
  }
  add-zsh-hook zshexit _tinty_cleanup

  # Apply initial theme directly to this terminal
  if [[ -n "$my_tty" ]]; then
    local scheme=$(_tinty_get_current_scheme)
    if [[ -n "$scheme" ]]; then
      local theme=$(_tinty_theme_for_scheme "$scheme")
      $TINTY_BIN apply "$theme" > "$my_tty" 2>/dev/null
    fi
  fi

  # DBus watcher — monitors portal for color-scheme changes
  {
    local last_applied=""
    "$DBUS_MONITOR" --session "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='org.freedesktop.appearance',arg1='color-scheme'" |
    while read -r line; do
      sleep 0.2  # Wait for signals to settle
      local scheme=$(_tinty_get_current_scheme)

      # Only apply if different from last (debounce duplicates)
      if [[ -n "$scheme" && "$scheme" != "$last_applied" ]]; then
        last_applied="$scheme"
        _tinty_apply_for_scheme "$scheme" &!
      fi
    done
  } >/dev/null 2>&1 &

  TINTY_PORTAL_WATCHER_PID=$!
  disown
}

# Run watcher only after ZLE has fully initialized (cursor is set, prompt ready)
add-zle-hook-widget zle-line-init tinty_portal_zle_init
