<h1 align="center">Tnux</h1>
<p align="center">A <a href="https://github.com/manaflow-ai/cmux">cmux</a> fork tuned for running many AI coding agents side by side.</p>
<p align="center"><a href="https://martinmana808.github.io/tnux/">Landing</a> · <a href="https://github.com/martinmana808/tnux/releases">Download</a> · <a href="docs/tnux-changes.md">What changed</a></p>

Tnux is cmux, the Ghostty-based macOS terminal with vertical tabs and agent notifications, plus a stack of hacks for one workload: thirty-odd panes across a few workspaces, most of them hosting a Claude Code session, and never losing track of which is which.

## What it adds

| Area | What you get |
| --- | --- |
| Pane identity | Every pane gets a stable pastel color and a `folder — title` chip. The focused pane's header takes the color (black chrome); its terminal goes a shade darker. |
| Aging | Chips show time since last focus (`4m`, `3h`, `2d`) and fade as panes go stale. Nothing moves. |
| Restart that restores | Fixed panes swapping sessions and folders after a relaunch. Rolling layout backups every 5 minutes, with History › Restore Layout From Backup…. |
| Grid layouts | Arrange menu (1–4 rows/columns), `⌘⌃1…9` rows, `⌘⌥1…9` columns, `cmux arrange-panes --rows 3`. |
| Panes menu | Every pane in every window with agent status: 🔔 needs input, ⚡ running, 💤 idle. |
| History | Recently Focused, 30 deep, listed `folder — pane - workspace`. |
| Pane search | `⌘P` lists every pane across workspaces, searchable by folder or title. |
| Workspace colors | Workspaces color themselves from the palette: a dot before the name and the selected highlight. |
| Pane cycling | `⌃⇧⌥→` / `⌃⇧⌥←` cycle panes; a zoomed pane hands the zoom along. |

Details: [docs/pane-identity.md](docs/pane-identity.md), [docs/session-backups.md](docs/session-backups.md), [docs/tnux-changes.md](docs/tnux-changes.md).

## Install

Grab `Tnux.zip` from the [Releases](https://github.com/martinmana808/tnux/releases) page, unzip, and move `Tnux.app` to `/Applications`. Builds are ad-hoc signed (Apple Silicon, macOS 14+); on first launch right-click › Open, or:

```sh
xattr -dr com.apple.quarantine /Applications/Tnux.app
```

Tnux keeps cmux's bundle id, so existing cmux settings, sessions and the `cmux` CLI keep working.

## Build

```sh
./scripts/setup.sh
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS' -disableAutomaticPackageResolution build
```

The product is `Tnux.app`. `scripts/hacks/swap-personal-app.py --daemon --now` installs a fresh build over a running one: it quits the app, repairs the saved layout, swaps the bundle (keeping the old one as `Tnux.previous.app`) and relaunches.

## Layout of this repo

Same as upstream cmux (see [docs/README-cmux-upstream.md](docs/README-cmux-upstream.md)); Tnux-specific code lives mostly in `Sources/Workspace+PanelLifecycle.swift`, `Sources/cmuxApp+HistoryMenu.swift`, and the `tab-color` branch of the [bonsplit fork](https://github.com/martinmana808/bonsplit) vendored at `vendor/bonsplit`. `upstream` is the cmux remote for merging updates.

## Credits

cmux is by [manaflow-ai](https://github.com/manaflow-ai/cmux). Tnux is a personal fork by tinus.
