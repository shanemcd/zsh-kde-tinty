# Desktop → tinty auto-sync plugin (ZLE-safe, debounced, race-free)
# Uses freedesktop.org XDG Desktop Portal for cross-desktop compatibility

# Only run in interactive shells with a terminal
if [[ ! -t 0 || -z "$TERM" || "$TERM" == "dumb" ]]; then
  return
fi

# Safe initialization once ZLE is active & PATH is ready
autoload -Uz add-zle-hook-widget

# Apply theme based on color-scheme value (0=light, 1=dark, 2=light)
_tinty_apply_for_scheme() {
  local color_scheme=$1

  {
    flock -n 9 || exit 0  # If another tab is applying, skip

    if [[ "$color_scheme" == "1" ]]; then
      $TINTY_BIN apply "$ZSH_TINTY_DARK" > /dev/tty 2>/dev/null
    else
      $TINTY_BIN apply "$ZSH_TINTY_LIGHT" > /dev/tty 2>/dev/null
    fi
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

tinty_portal_zle_init() {
  # Prevent duplicates - only run once per shell session
  if [[ -n "$TINTY_PORTAL_WATCHER_RUNNING" ]]; then
    return 0
  fi
  export TINTY_PORTAL_WATCHER_RUNNING=1

  # Remove the hook so it doesn't run again
  add-zle-hook-widget -d zle-line-init tinty_portal_zle_init

  # Disable job control notifications for this function
  setopt LOCAL_OPTIONS NO_NOTIFY NO_MONITOR

  # Resolve binaries AFTER PATH is ready and export for use in background jobs
  export TINTY_BIN=$(command -v tinty)
  local DBUS_MONITOR=$(command -v dbus-monitor)

  # If anything is missing, bail silently
  [[ -z "$TINTY_BIN" || -z "$DBUS_MONITOR" ]] && return 0

  # User-overridable theme names (export for background jobs)
  export ZSH_TINTY_LIGHT="${ZSH_TINTY_LIGHT:-base16-ia-light}"
  export ZSH_TINTY_DARK="${ZSH_TINTY_DARK:-base16-ia-dark}"

  # Initial application - get current scheme and apply
  {
    local current_scheme=$(_tinty_get_current_scheme)
    if [[ -n "$current_scheme" ]]; then
      _tinty_apply_for_scheme "$current_scheme"
    fi
  } &!

  # DBus watcher — monitors freedesktop portal for color-scheme changes
  {
    "$DBUS_MONITOR" --session "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'" |
    while read -r line; do
      # Look for org.freedesktop.appearance namespace
      if [[ "$line" == *"org.freedesktop.appearance"* ]]; then
        # Read next few lines to find color-scheme
        local check_next=5
        while ((check_next > 0)); do
          read -r line
          ((check_next--))
          if [[ "$line" == *"color-scheme"* ]]; then
            # Next line should have the value
            read -r line
            if [[ "$line" =~ uint32[[:space:]]+([0-9]+) ]]; then
              _tinty_apply_for_scheme "${match[1]}" &!
              break
            fi
          fi
        done
      fi
    done
  } >/dev/null 2>&1 &

  TINTY_PORTAL_WATCHER_PID=$!
  disown

  # Clean up on shell exit
  tinty_portal_cleanup() {
    [[ -n "$TINTY_PORTAL_WATCHER_PID" ]] && kill "$TINTY_PORTAL_WATCHER_PID" 2>/dev/null
  }

  add-zsh-hook zshexit tinty_portal_cleanup

  return 0
}

# Run watcher only after ZLE has fully initialized (cursor is set, prompt ready)
add-zle-hook-widget zle-line-init tinty_portal_zle_init
