# Pane identity: colors, focus, and aging

Every terminal pane in this fork gets a stable identity color the first time
it is titled (golden-ratio hue stepping, pastel enough that black text always
reads on it). The color shows up in three places.

## Tab chips

Each tab's title is drawn on a chip in the pane's color with black text,
whether or not that pane is focused, and without the leading terminal icon.
The chip's fill is an age gauge (see below).

## Focused pane

The pane that holds keyboard focus is marked by its header:

- its tab bar strip becomes one side-to-side pill in the selected tab's
  color (the chips' corner radius, 1pt inset), and everything drawn on it
  (close, pin and zoom buttons, badges, split actions, the title at every
  gauge level) is black so it reads on pastel;
- its terminal background goes a tad darker than the theme background (12
  percent toward black), done with a standard OSC 11 change injected into the
  pane's parser and undone with OSC 111 when focus leaves. Text colors are
  untouched.

A full identity-color background with a light palette was tried first; grays,
whites and reds in agent output read badly on pastel, so only the strip
carries the color. Unfocused panes keep the plain theme background. Remote
tmux mirror panes are left alone.

## Aging

cmux records the last time you acted in each pane (sent a message to the
agent or ran a command; focusing alone does not count, nor does the agent
replying) and stamps it into the tab title as a hidden marker. The chip is
an age gauge with one meaning: **full = you touched this pane today.**

- Days run 05:00 to 05:00, so work at 03:00 still belongs to the previous
  day and the chip drops one step at 05:00, not at midnight.
- After the first boundary the fill steps down once per day on a log scale:
  1 day 80%, 6 days 43%, 13 days 23%, 20 days 11%, empty at 30 days.
  Nothing changes inside a day.
- Text over the fill is black, text past it takes the chip color (black on
  the focused pane's strip), and a stroke keeps the full outline.
- A pane with no known action draws empty, never full.
- Hover a chip for "Last action: <date> (<n> days ago)".

The stamps come from three sources, the latest winning: Enter pressed in the
pane, the Claude `UserPromptSubmit` hook, and the Claude session transcript
(`~/.claude/projects/<slug>/<session>.jsonl`, last human message, parsed
from the file tail once a minute; the file's modification time is useless
because a resume rewrites it). The first launch of this build replaced the
stamps written before actions were tracked with the transcript dates.
Nothing is reordered; the stamps persist in the session snapshot.

## Recent Actions (Focus Back / Forward)

Cmd+[ and Cmd+] walk the panes ordered by your last action, most recent
first, across the window's workspaces. A pane you only focused never enters
the list. From a pane in the list, Cmd+[ goes to the next older one and
Cmd+] to the next newer; from a pane you never acted in, Cmd+[ goes to the
last place you wrote. Acting in any pane puts it at the top. Zoom follows
the focus. The History menu's "Recent Actions" section (30 entries) and the
command palette (15) list the same order as `folder — title - workspace`
with the time of the last action.

## Sidebar panes

Every workspace row in the left sidebar has a chevron. Collapsed (the
default) it looks as before; expanded it lists the workspace's panes, one
row each: identity dot, `folder — title`, status icon (bell = needs input,
bolt = running) and a small age gauge with the chip's semantics. The
expanded set is remembered. When a collapsed workspace is the selected one,
only its focused pane shows beneath it (an Arc-style peek), and it never
auto-expands. "Needs input" and "Running" sections sit above the list.

Footer buttons, the Panes menu and the command palette share three
choices, all persisted: Expand All / Collapse All, View All Panes (a flat
list of every pane with the workspace name in muted text, workspace rows
hidden) and Sort by Last Prompted (within expanded workspaces and in View
All; the default is layout order). Clicking a row focuses that pane.

## Where it lives

- Chip gauge, strip pill and black chrome: `vendor/bonsplit` (`TabItemStyling`,
  `TabBarChromeSnapshot`), tracked on the `tab-color` branch of the
  `martinmana808/bonsplit` fork.
- Focus scheme and last-action tracking: `Sources/Workspace+PanelLifecycle.swift`
  (`PaneFocusColorScheme`, `applyPaneFocusScheme`, `notePaneAction`), the
  terminal active-state sync in `Sources/Workspace.swift`, and the Enter
  stamp in the terminal view's key path.
- Action history and the shared focus path: `Sources/PaneActionHistory.swift`
  (`PaneActionHistory`, `TabManager.navigateActionHistory`,
  `AppDelegate.focusPane`); transcript parsing in
  `Sources/ClaudeTranscriptLastAction.swift`, the once-a-minute merge in
  `Sources/AppDelegate+PaneLastActionRefresh.swift`.
- Sidebar panes: `Sources/SidebarPanesModel.swift` (snapshot, preferences,
  model) and `Sources/SidebarPanesViews.swift`, mounted from
  `VerticalTabsSidebar` in `Sources/ContentView.swift`.
- Palette entries: `commandPaletteCommandContributions` in
  `Sources/ContentView.swift`.

## Arranging panes as a grid

"Arrange Panes in 2/3 Rows" and "Arrange Panes in 2/3 Columns" in the command
palette, or `cmux arrange-panes --rows <n>` / `--columns <n>` from a shell,
rebuild the focused workspace's split tree as an even grid: every surface gets
its own pane, groups are filled in the current on-screen order (larger groups
first when the count does not divide evenly, so 7 panes in 3 rows gives
3/2/2), and dividers equalize: once immediately and again after the layout
has settled (the same pass as Equalize Splits), so the grid ends even without
a manual Cmd+Ctrl+=. Nothing is closed or created, zoom is cleared, and focus
returns to the pane that had it. Socket method:
`workspace.arrange_panes` with `rows` or `columns`.
