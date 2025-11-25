# zsh-auto-tinty

> Auto-sync your terminal's color scheme with your desktop's light/dark mode using `tinty`.

`zsh-auto-tinty` is a small Oh My Zsh–style plugin that watches your desktop's theme changes over D-Bus and updates your terminal color scheme via [`tinty`](https://github.com/gtramontina/tinty) automatically.

It is designed for:

- KDE Plasma 5.24+, GNOME, and other XDG-compliant desktops
- Any terminal that supports tinty (Konsole, Alacritty, kitty, etc.)
- Oh My Zsh (or any Zsh plugin manager)
- People who like auto light/dark switching and consistent terminal themes

---

## Why this exists

Modern desktops can automatically switch between light and dark color schemes based on time of day or a schedule. Most terminals have their own color schemes that don't follow the desktop's light/dark mode automatically.

This plugin:

- Listens to the freedesktop.org XDG Desktop Portal for theme changes
- Monitors the `color-scheme` setting via D-Bus
- Maps the desktop theme to a **light** or **dark** `tinty` theme
- Applies the appropriate terminal colorscheme with `tinty apply`
- Runs inside each terminal tab's Zsh session (required for tinty to work)
- Uses ZLE-safe hooks, debouncing, and a simple lock to avoid race conditions

You get:

- Seamless desktop → terminal theme syncing
- Clean background operation with proper cleanup

---

## Features

- 🌓 Automatic light/dark sync with your desktop's theme
- 🎨 Terminal theming via `tinty` (Base16 or custom themes)
- 🖥️ Cross-desktop support (KDE, GNOME, etc.)
- 🛡 ZLE-safe initialization
- 🔁 Debounced & locked tinty calls
- ⚙️ Customizable theme mapping
- 💼 Tested with Oh My Zsh (should work with other Zsh plugin managers)

---

## Requirements

- Zsh
- Any terminal that supports tinty's escape sequences
- Desktop with XDG Desktop Portal support (KDE Plasma 5.24+, GNOME 42+, etc.)
- `dbus-monitor`
- `dbus-send`
- `tinty`
- `flock`

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

---

## How it works

### 1. Portal-based theme detection
Uses the freedesktop.org XDG Desktop Portal to detect system theme changes.

### 2. ZLE-safe initialization
Uses `zle-line-init` so cursor and widgets are stable.

### 3. D-Bus watcher
Monitors portal signals for `color-scheme` changes.

### 4. Debouncing
Multiple events are debounced with a 200ms delay.

### 5. Locking
Ensures only one tab applies theme changes at a time.

### 6. Direct value mapping
Portal returns 0 (light), 1 (dark), or 2 (light) - simple and reliable.

---

## Troubleshooting

### Plugin doesn't seem to work

Verify required commands are installed:

```bash
command -v tinty
command -v dbus-monitor
command -v dbus-send
command -v flock
```

Make sure you've configured your light/dark theme names in `~/.zshrc` before loading the plugin.

Check if your desktop supports the XDG Desktop Portal:

```bash
dbus-send --session --print-reply --dest=org.freedesktop.portal.Desktop \
  /org/freedesktop/portal/desktop \
  org.freedesktop.portal.Settings.Read \
  string:'org.freedesktop.appearance' \
  string:'color-scheme'
```

This should return a value (0, 1, or 2).

---

## Contributing

- PRs welcome
- Keep plugin lightweight and ZLE-safe
- Open issues for new terminals or color detection enhancements

---

## License

MIT
