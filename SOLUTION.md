# Adding macOS Support to zsh-auto-tinty

## The Problem

The original `zsh-auto-tinty` plugin worked on Linux by:
1. Monitoring D-Bus signals from the XDG Desktop Portal for theme changes
2. Capturing escape sequences from `tinty apply`
3. Broadcasting those escape sequences to all terminal tabs

This approach broke down on macOS for two reasons:
1. No D-Bus on macOS - needed a different way to detect theme changes
2. `tinty apply` behaves differently per terminal - on iTerm it runs AppleScript directly and outputs nothing to stdout

## The Journey

### Step 1: Detecting Theme Changes on macOS

macOS broadcasts `AppleInterfaceThemeChangedNotification` via `DistributedNotificationCenter` when the system theme changes. We built [macwatch](https://github.com/shanemcd/macwatch), a Swift CLI tool that listens to these notifications.

**Key insight**: You must use `import Cocoa` and `NSApplication.shared.run()` - using Foundation alone with `RunLoop.main.run()` doesn't receive distributed notifications.

```swift
import Cocoa
// ...
center.addObserver(forName: nil, object: nil, queue: .main) { notification in
    print(notification.name.rawValue)
}
NSApplication.shared.run()
```

### Step 2: The Broadcasting Problem

Our first attempt on macOS tried the same approach as Linux:
1. Run `tinty apply` and capture output
2. Write that output to all terminal TTYs

This failed because `tinty apply` outputs nothing on macOS. Looking at tinty's config:

```toml
hook = '''
command cp -f %f ~/Library/Application\ Support/iTerm2/Scripts/AutoLaunch.scpt \
  && osascript %f
'''
```

Tinty runs AppleScript directly for iTerm - there are no escape sequences to capture.

We tried parsing the AppleScript and modifying it to iterate all windows/tabs, but this felt fragile and terminal-specific.

### Step 3: The Signal-Based Solution

The fundamental insight: **each shell should run `tinty apply` for itself**.

`tinty` already knows how to apply themes to whatever terminal it's running in. We don't need to understand or broadcast terminal-specific escape sequences - we just need to tell each shell "hey, the theme changed, run tinty."

The new architecture:
1. Each shell registers its PID in `/tmp/tinty-shells/<PID>`
2. One shell acquires `/tmp/tinty-watcher.lock` and runs the watcher
3. When theme changes, the watcher sends `SIGUSR1` to all registered shells
4. Each shell's `TRAPUSR1` handler runs `tinty apply`

```zsh
# Signal handler
TRAPUSR1() {
  $TINTY_BIN apply "$(_tinty_theme_for_scheme $(_tinty_get_current_scheme))"
}

# Watcher broadcasts to all shells
_tinty_signal_all_shells() {
  for pidfile in /tmp/tinty-shells/*(N); do
    kill -USR1 "$(cat "$pidfile")" 2>/dev/null
  done
}
```

## Key Learnings

1. **Terminal-agnostic is better than terminal-specific**: Instead of understanding each terminal's escape sequences or AppleScript, let `tinty` handle it.

2. **Signals for IPC**: Unix signals are a simple, reliable way to notify multiple processes. `SIGUSR1` is perfect for "something changed, update yourself."

3. **macOS distributed notifications require Cocoa**: Foundation's RunLoop doesn't dispatch distributed notifications. You need the full Cocoa event loop via `NSApplication.shared.run()`.

4. **Zsh glob qualifiers**: Use `*(N)` to avoid "no matches found" errors when a glob might be empty.

5. **mkdir as a lock**: On macOS (no `flock`), `mkdir` is atomic and works as a simple lock mechanism.

## Platform Differences

| Aspect | Linux | macOS |
|--------|-------|-------|
| Theme change detection | `dbus-monitor` | `macwatch` |
| Theme query | `dbus-send` to portal | `defaults read -g AppleInterfaceStyle` |
| Locking | `flock` | `mkdir` (atomic) |
| Theme application | `tinty apply` (same) | `tinty apply` (same) |

## Dependencies

- **Linux**: `tinty`, `dbus-monitor`, `dbus-send`
- **macOS**: `tinty`, `macwatch`
