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

    # Get tinty output once
    local tinty_output
    if [[ "$color_scheme" == "1" ]]; then
      tinty_output=$($TINTY_BIN apply "$ZSH_TINTY_DARK" 2>/dev/null)
    else
      tinty_output=$($TINTY_BIN apply "$ZSH_TINTY_LIGHT" 2>/dev/null)
    fi

    # Apply only to registered shells (those that loaded this plugin)
    if [[ -d /tmp/tinty-shells ]]; then
      for pts_num in /tmp/tinty-shells/*; do
        [[ -e "$pts_num" ]] || continue
        local pts="/dev/pts/$(basename "$pts_num")"

        # Verify the shell is still running
        local shell_pid=$(cat "$pts_num" 2>/dev/null)
        if [[ -n "$shell_pid" ]] && kill -0 "$shell_pid" 2>/dev/null; then
          if [[ -w "$pts" && -c "$pts" ]]; then
            printf '%s' "$tinty_output" > "$pts" 2>/dev/null
          fi
        else
          # Clean up stale registration
          rm -f "$pts_num"
        fi
      done
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

  # Register this shell's TTY so only plugin-aware terminals get theme updates
  local my_tty=$(tty 2>/dev/null)

  # Try multiple fallbacks to find the actual pts device
  if [[ ! "$my_tty" =~ ^/dev/pts/([0-9]+)$ ]]; then
    # Try fd 0, 1, 2 in order
    for fd in 0 1 2; do
      my_tty=$(readlink /proc/self/fd/$fd 2>/dev/null)
      [[ "$my_tty" =~ ^/dev/pts/([0-9]+)$ ]] && break
    done
  fi

  # Final fallback: use ps to get the controlling terminal
  if [[ ! "$my_tty" =~ ^/dev/pts/([0-9]+)$ ]]; then
    local ctty=$(ps -p $$ -o tty= 2>/dev/null | tr -d ' ')
    if [[ "$ctty" =~ ^pts/([0-9]+)$ ]]; then
      my_tty="/dev/$ctty"
    fi
  fi

  local my_pts_num=""
  if [[ -n "$my_tty" && "$my_tty" =~ ^/dev/pts/([0-9]+)$ ]]; then
    my_pts_num="${match[1]}"
    mkdir -p /tmp/tinty-shells
    echo $$ > "/tmp/tinty-shells/$my_pts_num"
  fi

  # Clean up registration on exit - but ONLY for the main shell, not subshells/background jobs
  tinty_cleanup_registration() {
    # Only clean up if this is the top-level shell (not a subshell or background job)
    # $ZSH_SUBSHELL is 0 in the main shell, >0 in subshells
    if [[ $ZSH_SUBSHELL -eq 0 && -n "$my_pts_num" ]]; then
      rm -f "/tmp/tinty-shells/$my_pts_num"
    fi
  }
  add-zsh-hook zshexit tinty_cleanup_registration

  # Initial application - apply directly to this terminal (not via broadcast)
  if [[ -n "$my_tty" ]]; then
    local current_scheme=$(_tinty_get_current_scheme)
    if [[ -n "$current_scheme" ]]; then
      if [[ "$current_scheme" == "1" ]]; then
        $TINTY_BIN apply "$ZSH_TINTY_DARK" > "$my_tty" 2>/dev/null
      else
        $TINTY_BIN apply "$ZSH_TINTY_LIGHT" > "$my_tty" 2>/dev/null
      fi
    fi
  fi

  # DBus watcher — monitors freedesktop portal for color-scheme changes
  {
    local last_applied=""
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
            # Wait 200ms for signals to settle, then poll actual value
            sleep 0.2
            local current_scheme=$(_tinty_get_current_scheme)

            # Only apply if different from last applied (debounce duplicates)
            if [[ -n "$current_scheme" && "$current_scheme" != "$last_applied" ]]; then
              last_applied="$current_scheme"
              _tinty_apply_for_scheme "$current_scheme" &!
            fi
            break
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
