# Tnux: what changed since the fork

Tnux is cmux with a stack of personal "hacks" layered on top. This page is the
running changelog, newest first. Everything here lives on `main` of the
cmux-hacks checkout; the bonsplit pieces live on the `tab-color` branch of
`martinmana808/bonsplit`.

## October 2026

- **Focused chip stays black.** On the focused pane's colored strip the
  title is black at every gauge level. Workspace colors are opt-in again
  (pick from the workspace context menu); auto-assigned ones are cleared once.
- **Gauge measures actions, not focus.** The chip fill now tracks the last
  Enter pressed in the pane (message sent, command run). The leading terminal
  icon is gone from chip tabs, and the focused pane's strip is a single
  side-to-side pill with the chip's radius.
- **Age gauge chips.** The tab chip's color fill shrinks from the right as the
  pane goes stale (log scale, full under 10 minutes, empty at 14 days); black
  text over the fill, tab-colored text past it, stroke at full width. Replaces
  the "4m / 2d" badge.
- **Pane search.** Cmd+P (Go to Workspace) lists every pane in every workspace
  and searches by title; entries read "folder - title" so a project name finds
  its panes (`app.commandPaletteSearchesAllSurfaces` in `cmux.json`).
- **Project folder everywhere.** Recently Focused rows, Panes menu entries and
  the switcher carry the pane's folder prefix, like the tab chips.
- **Repo and landing.** Source lives at github.com/martinmana808/tnux (full
  cmux history, `upstream` remote kept for merges); landing page at
  martinmana808.github.io/tnux; builds on the Releases page.
- **Renamed to Tnux.** The Release build is now `Tnux.app` (bundle id unchanged,
  so settings, sessions and sockets carry over). The install job moves the old
  "cmux Personal" bundle aside as `Tnux.previous.app`.
- **Arrange menu.** 1 to 4 columns, 1 to 4 rows, plus Equalize Splits.
- **Arrange shortcuts.** Cmd+Ctrl+1…9 arranges the workspace in N rows,
  Cmd+Option+1…9 in N columns. Both are rebindable in Settings and `cmux.json`
  (`arrangePanesRowsByNumber`, `arrangePanesColumnsByNumber`).
- **Panes menu.** Every pane across every window and workspace, with its agent
  status: 🔔 needs input, ⚡ running, 💤 idle. Needs-input and running panes are
  listed first; pick one to jump there.
- **History menu.** "Recently Closed" removed; "Recently Focused" grown from 10
  to 30 entries and listed pane first ("pane — workspace").
- **Workspace color dot.** A workspace with a color (picked from its context
  menu) shows it as a dot before its name as well as its selected highlight.
- **Grid arrangement.** `cmux arrange-panes --rows N | --columns N`, the
  `workspace.arrange_panes` socket method, and palette entries. Every surface
  keeps its own pane; panes fill in on-screen order; dividers equalize.
- **Focused pane look.** The focused pane's tab strip takes the tab color with
  black chrome; its terminal background goes 12 percent darker. A full-color
  background with a light palette was tried and rolled back (grays, whites and
  reds read badly on pastel).
- **Header buttons hidden.** `ui.surfaceTabBar.buttons: []` in `cmux.json`
  removes the four action icons so the tab title gets the whole header.
- **Help > Tnux: What Changed** opens this page.

## September 2026

- **Restart shuffle fixed.** Panes no longer swap Claude sessions and folders
  after a relaunch. Root cause: restore re-applied each pane's pre-relaunch tty
  name, and panes started by a resume launcher never corrected it, so hook
  routing and process detection attributed sessions to the wrong panes. Pane
  ttys now come from the live pty via Ghostty.
- **Layout backups.** Rolling, timestamped copies of the session snapshot under
  `Application Support/cmux/session-backups/<bundle-id>/` (every 5 minutes
  when changed; all for 3 hours, hourly for 3 days, daily for 30 days), plus
  History > Restore Layout From Backup….
- **Pane cycling.** Ctrl+Shift+Option+Right/Left focus the next/previous pane
  in layout order, wrapping, and a zoomed pane hands the zoom to the target.
- **Tab chips everywhere.** Every tab shows its identity color as a solid chip
  with black text, focused or not.
- **Pane aging.** Chips show time since last focus ("4m", "3h", "2d") and fade
  from full at 10 minutes to 45 percent at a day. Nothing is reordered; the
  times survive a relaunch.
- **Recently Focused in the command palette.** The last 15 focus targets with
  workspace and relative time.
- **Install job.** `scripts/hacks/swap-personal-app.py` waits for idle (or
  `--now`), reports true ttys, quits the app, repairs the saved layout, installs
  the new Release build at the same path, and relaunches.

## July 2026

- **Tab colors.** Each pane gets a stable pastel identity color (golden-ratio
  hue stepping) and a color-dot title prefix with the folder's last segment.

## Where things live

- Behaviour docs: `docs/pane-identity.md`, `docs/session-backups.md`.
- Shortcuts: Settings > Keyboard Shortcuts, or `shortcuts.bindings` in
  `~/.config/cmux/cmux.json`.
- Backups: `~/Library/Application Support/cmux/session-backups/`.
- Install log: `~/Library/Logs/cmux-swap.log`.
