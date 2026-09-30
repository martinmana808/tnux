# Pane identity: colors, focus, and aging

Every terminal pane in this fork gets a stable identity color the first time
it is titled (golden-ratio hue stepping, pastel enough that black text always
reads on it). The color shows up in three places.

## Tab chips

Each tab's title is drawn on a solid chip in the pane's color with black text,
whether or not that pane is focused. The chip carries a small age badge and
fades as the pane goes stale (see below).

## Focused pane

The pane that holds keyboard focus is painted as one colored block:

- its tab bar strip takes the selected tab's color;
- its terminal switches to a light scheme: black default text, the pane
  color as background, black cursor, and a dark 16-color palette so dim
  grays and highlights stay readable on pastel.

The switch is done with standard terminal color sequences (OSC 4, 10, 11
and 12) injected into the pane's terminal parser, and undone with the
matching resets (OSC 104, 110, 111, 112) when focus leaves. Programs that
draw with palette colors, which is most of them, adapt automatically. A
program that hardcodes its own colors keeps them while focused.

Unfocused panes keep the plain theme background so the active pane stands
out. Remote tmux mirror panes are left alone.

## Aging

cmux records when each pane's terminal last became active and stamps it into
the tab title as a hidden marker. The chip then shows how long ago that was
("now", "4m", "3h", "2d"), refreshing once a minute, and its fill fades from
full at 10 minutes down to 45 percent at a day, never lower. Fresh panes stay
vivid and stale ones recede without any reordering. The timestamps persist in
the session snapshot, so ages survive a relaunch.

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
