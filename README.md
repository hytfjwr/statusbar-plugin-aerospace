# AeroSpace Plugin for StatusBar

[AeroSpace](https://github.com/nikitabobko/AeroSpace) tiling window manager workspace widget for [StatusBar](https://github.com/hytfjwr/StatusBar).

<img width="588" height="112" alt="image" src="https://github.com/user-attachments/assets/dba55bab-c536-4acd-a08d-25e8ca9b8fe9" />


## Features

- Workspace indicators with focused workspace highlight
- App icons per workspace
- Multi-monitor support
- Click to switch workspace
- Configurable update interval, icon size, and empty space visibility

## Install

In StatusBar preferences → Plugins → Add Plugin:

```
hytfjwr/statusbar-plugin-aerospace
```

## Setup

Add the following to your `~/.aerospace.toml` to enable real-time workspace change detection:

```toml
exec-on-workspace-change = [
  '/bin/bash', '-c',
  'sbar trigger "com.statusbar.aerospace.workspace_changed" --payload "$AEROSPACE_FOCUSED_WORKSPACE"'
]
```

Without this setting, the plugin falls back to polling-based updates only.

## Configuration

The following options are available in the widget settings:

| Option | Description | Default |
|--------|-------------|---------|
| Update interval | Polling interval for workspace list | 10s |
| Show app icons | Display app icons in each workspace | On |
| Icon size | App icon size (12–20px) | 16px |
| Show empty workspaces | Display workspaces with no windows | Off |

## Development

```bash
make build      # Release build
make dev        # Build & install locally
make release    # Build & publish GitHub Release
```

## Requirements

- macOS 26+
- [StatusBar](https://github.com/hytfjwr/StatusBar)
- [AeroSpace](https://github.com/nikitabobko/AeroSpace)

## License

MIT
