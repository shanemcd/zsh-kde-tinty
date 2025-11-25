# KDE → tinty auto-sync plugin (ZLE-safe, debounced, race-free)

# Only run in Konsole
if [[ -z "$KONSOLE_VERSION" && "$TERM" != xterm-kde* ]]; then
  return
fi

# Safe initialization once ZLE is active & PATH is ready
autoload -Uz add-zle-hook-widget

# Debounced tinty apply (race-safe) - defined globally for background dbus-monitor
_kde_tinty_apply_theme() {
  sleep 0.2

  {
    flock -n 9 || exit 0  # If another tab is applying, skip

    local scheme
    scheme="$($KDE_TINTY_KREAD --file kdeglobals --group General --key ColorScheme 2>/dev/null)"

    if [[ "$scheme" =~ [Dd]ark ]]; then
      $KDE_TINTY_TINTY apply "$ZSH_TINTY_DARK" > /dev/tty 2>/dev/null
    else
      $KDE_TINTY_TINTY apply "$ZSH_TINTY_LIGHT" > /dev/tty 2>/dev/null
    fi
  } 9>/tmp/kde-tinty.lock
}

kde_tinty_zle_init() {
  # Prevent duplicates - only run once per shell session
  if [[ -n "$KDE_TINTY_WATCHER_RUNNING" ]]; then
    return 0
  fi
  export KDE_TINTY_WATCHER_RUNNING=1

  # Remove the hook so it doesn't run again
  add-zle-hook-widget -d zle-line-init kde_tinty_zle_init

  # Disable job control notifications for this function
  setopt LOCAL_OPTIONS NO_NOTIFY NO_MONITOR

  # Resolve binaries AFTER PATH is ready and export for use in background jobs
  export KDE_TINTY_KREAD=$(command -v kreadconfig6)
  export KDE_TINTY_DBUSM=$(command -v dbus-monitor)
  export KDE_TINTY_TINTY=$(command -v tinty)

  # If anything is missing, bail silently
  [[ -z "$KDE_TINTY_KREAD" || -z "$KDE_TINTY_DBUSM" || -z "$KDE_TINTY_TINTY" ]] && return 0

  # User-overridable theme names (export for background jobs)
  export ZSH_TINTY_LIGHT="${ZSH_TINTY_LIGHT:-base16-ia-light}"
  export ZSH_TINTY_DARK="${ZSH_TINTY_DARK:-base16-ia-dark}"

  # Initial application (safe because ZLE is ready)
  ( _kde_tinty_apply_theme ) &!

  # DBus watcher — runs in background
  {
    "$KDE_TINTY_DBUSM" --session "type='signal',interface='org.kde.kconfig.notify',member='ConfigChanged'" |
    while read -r line; do
      if [[ "$line" == *"/kdeglobals"* ]]; then
        {
          sleep 0.2
          (
            flock -n 9 || exit 0
            scheme=$($KDE_TINTY_KREAD --file kdeglobals --group General --key ColorScheme 2>/dev/null)
            if [[ "$scheme" =~ [Dd]ark ]]; then
              $KDE_TINTY_TINTY apply "$ZSH_TINTY_DARK" > /dev/tty 2>/dev/null
            else
              $KDE_TINTY_TINTY apply "$ZSH_TINTY_LIGHT" > /dev/tty 2>/dev/null
            fi
          ) 9>/tmp/kde-tinty.lock
        } &!
      fi
    done
  } >/dev/null 2>&1 &

  KDE_TINTY_WATCHER_PID=$!
  disown

  # Clean up on shell exit
  kde_tinty_cleanup() {
    [[ -n "$KDE_TINTY_WATCHER_PID" ]] && kill "$KDE_TINTY_WATCHER_PID" 2>/dev/null
  }

  add-zsh-hook zshexit kde_tinty_cleanup

  return 0
}

# Run watcher only after ZLE has fully initialized (cursor is set, prompt ready)
add-zle-hook-widget zle-line-init kde_tinty_zle_init
