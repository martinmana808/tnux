# Pane identity: colors, focus, and aging

Every terminal pane in this fork gets a stable identity color the first time
it is titled (golden-ratio hue stepping, pastel enough that black text always
reads on it). The color shows up in three places.

## Tab chips

Each tab's title is drawn on a solid chip in the pane's color with black text,
whether or not that pane is focused. The chip carries a small age badge and
fades as the pane goes stale (see below).

## Focused pane

The pane that holds keyboard focus is marked by its header:

- its tab bar strip takes the selected tab's color, and everything drawn on
  that strip (tab icon, close, pin and zoom buttons, badges, split actions)
  turns black so it reads on pastel;
- its terminal background goes a tad darker than the theme background (12
  percent toward black), done with a standard OSC 11 change injected into the
  pane's parser and undone with OSC 111 when focus leaves. Text colors are
  untouched.

A full identity-color background with a light palette was tried first; grays,
whites and reds in agent output read badly on pastel, so only the strip
carries the color. Unfocused panes keep the plain theme background. Remote
tmux mirror panes are left alone.

## Aging

cmux records the last time you acted in each pane (pressed Enter: sent a
message to an agent or ran a command; focusing alone does not count) and
stamps it into the tab title as a hidden marker. The chip is then an age gauge: its color
fill shrinks from the right as the pane goes stale, on a log scale that is
full for the first 10 minutes, about three quarters at an hour, half at six
hours, a third at a day, and empty at two weeks. Text over the fill is black,
text past it takes the chip color, and a stroke keeps the full outline so you
can read how much is gone. It re-renders once a minute. Nothing is reordered;
the timestamps persist in the session snapshot, so ages survive a relaunch.

## Recently Focused

The command palette lists the last 15 focus targets as "Recently Focused"
entries, each with its workspace and a relative time, and jumps to one on
selection. The History menu's "Recently Focused" section and Focus Back /
Focus Forward (Cmd+[ / Cmd+]) walk the same history.

## Where it lives

- Chip, badge, fade and strip color: `vendor/bonsplit` (`TabItemStyling`,
  `TabBarChromeSnapshot`), tracked on the `tab-color` branch of the
  `martinmana808/bonsplit` fork.
- Focus scheme and last-focus tracking: `Sources/Workspace+PanelLifecycle.swift`
  (`PaneFocusColorScheme`, `applyPaneFocusScheme`) and the terminal
  active-state sync in `Sources/Workspace.swift`.
- Palette entries: `commandPaletteCommandContributions` in
  `Sources/ContentView.swift`.

## Arranging panes as a grid

"Arrange Panes in 2/3 Rows" and "Arrange Panes in 2/3 Columns" in the command
palette, or `cmux arrange-panes --rows <n>` / `--columns <n>` from a shell,
rebuild the focused workspace's split tree as an even grid: every surface gets
its own pane, groups are filled in the current on-screen order (larger groups
first when the count does not divide evenly, so 7 panes in 3 rows gives
3/2/2), and dividers equalize. Nothing is closed or created, zoom is cleared,
and focus returns to the pane that had it. Socket method:
`workspace.arrange_panes` with `rows` or `columns`.
