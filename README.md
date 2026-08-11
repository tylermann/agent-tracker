# Agent Tracker

Agent Tracker is a small native macOS sidecar for monitoring Claude Code, Codex CLI, and Cursor Agent sessions running in Ghostty. It shows which agents are working, waiting for feedback, asking for permission, or finished, and jumps directly to the corresponding Ghostty terminal.

## What it does

- Follows the focused Ghostty window as a detachable 320-point sidebar.
- Tracks tabs, splits, and windows independently, including multiple agents in the same repository.
- Uses each harness's lifecycle hooks instead of scraping terminal output.
- Shows a menu-bar unread count and sends actionable macOS notifications.
- Stores only local run metadata and a 120-character first-prompt preview; it stores no transcripts.
- Optionally shows compact remaining-usage meters for Claude, Codex, and Cursor by polling each provider with that product's existing local sign-in.
- Installs and removes its hooks and zsh wrappers without replacing unrelated configuration.

## Build and run

Requirements: macOS 14+, Xcode/Swift 6, Ghostty 1.3+, and at least one supported agent CLI.

```sh
make test
make app
open "dist/Agent Tracker.app"
```

To install the locally built, ad-hoc-signed app in `/Applications`:

```sh
make install
```

On first launch:

1. Grant Accessibility access so the panel can follow Ghostty windows.
2. Open Settings and test Ghostty Automation access.
3. Choose **Install or Repair** to add lifecycle hooks and zsh wrappers.
4. If Codex reports untrusted hooks, open `/hooks` once and approve the Agent Tracker entries.
5. Start a new shell, or run `source ~/.zshrc`.

Usage meters are off by default. Enable them in Settings to poll about every three minutes. The
feature reuses local OAuth credentials and calls undocumented first-party usage endpoints; no extra
API keys are needed, but providers may change these endpoints without notice. A failed refresh keeps
the last good reading marked as stale, while signed-out providers show that status directly. Local
credentials are read once per app launch and retained only in memory, so background polls do not
repeatedly access Keychain. Automatic polls do not show Keychain dialogs; use the sidebar refresh
button to explicitly authorize access when needed.

The integration installer creates timestamped backups before changing existing configuration. It adds one marked block to `~/.zshrc`, writes a managed `~/.config/agent-tracker/shell.zsh`, and merges marked hook commands into the harness settings. Existing Codex `notify` configuration is not touched.

## CLI

The app bundles a background-only helper at
`Agent Tracker.app/Contents/Helpers/Agent Tracker CLI.app/Contents/MacOS/agent-tracker`:

```text
agent-tracker doctor
agent-tracker install-integrations
agent-tracker uninstall-integrations
agent-tracker wrap --harness codex -- /path/to/codex
agent-tracker focus <ghostty-terminal-id>
```

The generated zsh functions invoke `wrap` transparently under the familiar `claude`, `codex`, `agent`, and `cursor-agent` names. The wrapper records the stable Ghostty terminal ID once, preserves the child's terminal I/O, and reports process exit. Hook subprocesses inherit the run ID and supply accurate lifecycle state.

## Architecture

- `AgentTrackerCore`: normalized events, inbox, SQLite reducer, Ghostty automation, and integration management.
- `agent-tracker`: hook receiver, transparent process wrapper, diagnostics, and installer CLI.
- `AgentTracker`: SwiftUI/AppKit menu-bar app, attached panel, notifications, and settings.
- Hook events are written atomically to an inbox. The app is the only SQLite writer, so events survive app restarts without requiring a resident socket daemon.

## Current boundaries

- Local Ghostty sessions only; remote SSH agents and other terminal emulators are not yet mapped.
- Monitoring and exact terminal focus only; the panel does not send prompts or terminate processes.
- Cursor's hook surface can report fewer explicit permission states than Claude or Codex. Its completed-turn and activity states remain reliable, while some permission waits may appear as ordinary waiting.
- Usage endpoints are unofficial/undocumented adapters. Meters degrade to logged-out, unavailable, or stale states when credentials or response formats change.

## License

MIT. See [LICENSE](LICENSE).
