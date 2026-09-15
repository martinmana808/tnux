# Session layout backups

cmux autosaves the full session layout (windows, workspaces, panes, surfaces,
working directories, and agent resume bindings) every few seconds to:

```
~/Library/Application Support/cmux/session-<bundle-id>.json
```

That file is the state restored on the next launch. A single `-previous`
copy only survives one bad relaunch, so cmux also keeps rolling backups.

## Rolling backups

Every time the primary snapshot changes, the save path records a timestamped
copy when the newest backup is at least 5 minutes old:

```
~/Library/Application Support/cmux/session-backups/<bundle-id>/2026-09-15_17-42-08.json
```

Backups are pruned automatically with three tiers:

| Age              | Kept                          |
| ---------------- | ----------------------------- |
| under 3 hours    | every backup (5-minute cadence) |
| 3 hours to 3 days | one per hour                  |
| 3 to 30 days     | one per day                   |

Older backups are deleted. At the defaults this stays under roughly 140 files.
Backup failures never fail the primary save. The policy lives in
`SessionSnapshotBackupPolicy` in the `CmuxWorkspaces` package.

## Restoring a backup

History > Restore Layout From Backup… opens the backups folder in a file
picker. The chosen snapshot restores the same way History > Restore Previous
Launch does: its windows open alongside the current ones, with every terminal
resumed from its recorded working directory and agent session where possible.

## Why pane tty names are not restored

Each pane's controlling tty is used to attribute agent hook events, running
processes, and listening ports to the right pane. A local pty does not survive
an app relaunch, so restore no longer re-applies the tty name saved in the
snapshot; the app reads the live pty name from Ghostty instead and refreshes
its table whenever a consumer asks. Remote terminals keep the persisted name,
because a remote PTY can outlive the app. This prevents agent sessions and
working directories from being attributed to the wrong pane, and then restored
into the wrong pane, after a relaunch.
