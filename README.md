# zsh-auto-tinty

> Auto-sync your terminal's color scheme with your desktop's light/dark mode using `tinty`.

`zsh-auto-tinty` is a small Oh My Zsh–style plugin that watches your desktop's theme changes and updates your terminal color scheme via [`tinty`](https://github.com/gtramontina/tinty) automatically.

It is designed for:

- **Linux** — KDE Plasma 5.24+, GNOME, and other XDG-compliant desktops
- **macOS** — dark/light mode changes via the system appearance
- Any terminal that supports tinty (Konsole, Ghostty, iTerm2, Alacritty, kitty, etc.)
- Oh My Zsh (or any Zsh plugin manager)
- People who like auto light/dark switching and consistent terminal themes

---

## Why this exists

Modern desktops can automatically switch between light and dark color schemes based on time of day or a schedule. Most terminals have their own color schemes that don't follow the desktop's light/dark mode automatically.

This plugin:

- Detects the current desktop theme (Linux XDG Desktop Portal or macOS appearance)
- Watches for theme changes in real time
- Maps the desktop theme to a **light** or **dark** `tinty` theme
- Applies the appropriate terminal colorscheme with `tinty apply`
- Runs inside each terminal tab's Zsh session (required for tinty to work)
- Uses ZLE-safe hooks, debouncing, and file locks to avoid race conditions

You get:

- Seamless desktop → terminal theme syncing on Linux and macOS
- Clean background operation with proper cleanup on shell exit

---

## Features

- 🌓 Automatic light/dark sync with your desktop's theme
- 🎨 Terminal theming via `tinty` (Base16/Base24 or custom themes)
- 🖥️ Cross-platform support (Linux XDG + macOS)
- 🛡 ZLE-safe initialization
- 🔁 Debounced & locked tinty calls
- 🧵 Race-free across multiple terminal tabs (single watcher + serialized applies)
- ⚙️ Customizable theme mapping
- 💼 Tested with Oh My Zsh (should work with other Zsh plugin managers)

---

## Requirements

### All platforms

- Zsh
- Any terminal that supports tinty's escape sequences
- `tinty` (with `items` hooks configured for your terminal — e.g. Ghostty, iTerm2)

### Linux

- A desktop with XDG Desktop Portal support (KDE 6, GNOME 42+, etc.)
- `dbus-monitor`
- `dbus-send`
- `flock`

The plugin uses the freedesktop.org XDG Desktop Portal to read/wire the system `color-scheme` and listens to portal change signals via D-Bus.

### macOS

- [**macwatch**](https://github.com/shanemcd/macwatch) — a small Swift companion tool that watches `DistributedNotificationCenter` and prints `AppleInterfaceThemeChangedNotification` (a `dbus-monitor`-like event stream). Install it and make sure it's on your `PATH`.

```bash
git clone https://github.com/shanemcd/macwatch.git
cd macwatch
swift build -c release
cp .build/release/macwatch ~/.local/bin/
```

The plugin detects the current appearance with `defaults read -g AppleInterfaceStyle` and reacts to changes as they happen via macwatch. No D-Bus is involved on macOS.

---

## Installation

### Oh My Zsh

```bash
git clone https://github.com/shanemcd/zsh-auto-tinty ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/auto-tinty
```

Then enable in `~/.zshrc`:

```zsh
plugins+=(auto-tinty)
```

Reload:

```bash
exec zsh
```

---

## Configuration

In your `~/.zshrc`:

```zsh
export ZSH_TINTY_LIGHT="base16-ia-light"
export ZSH_TINTY_DARK="base16-ia-dark"
```

The plugin maps 0 (light) and 1 (dark) to these two theme names.

---

## How it works

### 1. ZLE-safe initialization

Uses `zle-line-init` so cursor and widgets are stable when the plugin first runs.

### 2. Theme detection

- **Linux:** reads the XDG Desktop Portal `org.freedesktop.appearance` `color-scheme` (0=light, 1=dark, 2=auto-light). The XDG Portal is the source of truth for the desktop theme.
- **macOS:** `defaults read -g AppleInterfaceStyle` returns `Dark` (or empty for light).

### 3. Real-time watcher (single instance)

Only one shell across all tabs runs the watcher, protected by a PID-based lock so tabs can't each spawn their own. On a theme change it re-checks the current scheme.

- **Linux:** the watcher listens for portal `SettingChanged` signals over D-Bus, then sends `SIGUSR1` to every registered shell so each applies locally.
- **macOS:** the watcher runs `macwatch --include AppleInterfaceThemeChangedNotification` and applies the new theme once. tinty's own hooks propagate it to the terminal (e.g. Ghostty `SIGUSR2`, iTerm2 AppleScript).

### 4. Debouncing

Multiple rapid events are settled with a short delay before applying.

### 5. Locking

Applies are serialized with an atomic `mkdir` mutex (on Linux, `flock`) so concurrent tabs can never clobber each other with different themes. Stale owners (dead PIDs) are automatically reaped.

---

## Troubleshooting

### Plugin doesn't seem to work

First, reload your shells with `exec zsh` — each tab must re-initialize and re-register.

Verify required commands are installed:

**Linux**
```bash
command -v tinty dbus-monitor dbus-send flock
```

**macOS**
```bash
command -v tinty macwatch
# macwatch should already be on PATH and runnable:
macwatch --include AppleInterfaceThemeChangedNotification
```

Make sure you've configured your light/dark theme names in `~/.zshrc` before loading the plugin.

Debug logging is written to `/tmp/tinty-debug.log`. Watch it live while toggling appearance:

```bash
tail -f /tmp/tinty-debug.log
```

(You'll see `START` → `ZLE_INIT` → `WATCHER` → `APPLY`-lines as the theme flips.)

### Linux: portal returns no value

```bash
dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop \
  /org/freedesktop/portal/desktop \
  org.freedesktop.portal.Settings.Read \
  string:'org.freedesktop.appearance' \
  string:'color-scheme'
```

This should return a value (0, 1, or 2).

### macOS: terminal colors don't change

Make sure tinty has the hook for your terminal configured in `~/.config/tinted-theming/tinty/config.toml` (e.g. the `tinted-terminal-iterm2` or `tinted-terminal-ghostty` `[[items]]` entries). On macOS the plugin relies on those hooks — applying via stdout escapes only works on terminals that toggle on ANSI output, which most macOS terminals don't.

---

## Contributing

- PRs welcome
- Keep plugin lightweight and ZLE-safe
- Keep the cross-platform logic (Linux XDG + macOS macwatch) separate and readable
- Open issues for new terminals or color-detection enhancements

---

## License

MIT