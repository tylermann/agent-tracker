# Feature Ideas

Personal feature backlog for Agent Tracker, based on how it actually gets used
day to day: agents running in Ghostty across many repos, frequent session
resuming, constant git-status checking, and hopping between agents that need
attention.

## 1. Session resume launcher — implemented

The most repeated pattern in daily use is resuming past sessions
(`codex resume`, `claude --resume`, `claude --continue`). The lifecycle hooks
already capture each session's ID, harness, and working directory.

- Add a "recent / ended sessions" section, grouped by repository.
- Clicking a row opens a new Ghostty tab in the session's working directory
  and runs the exact resume command for that harness
  (`codex resume <id>`, `claude --resume <id>`).
- Use the stored 120-character first-prompt preview as the row label, which is
  more scannable than the harnesses' own interactive resume pickers.

## 2. Git state on each run row — implemented

A small file icon and dirty-file count sit next to the existing branch on each
row. They refresh when a run needs attention, is waiting, or has ended — not on
every activity tick, and not in notifications.

## 3. Global hotkey: jump to next waiting agent — implemented

The app already jumps to Ghostty surfaces; make that keyboard-driven:

- A system-wide hotkey that focuses the oldest agent in a
  "waiting for feedback" or "asking for permission" state.
- Pressing it repeatedly cycles through all waiting agents, turning the
  sidebar into a queue to drain without mouse or scanning.
- `⌘⇧\` runs the action, and the sidebar header's info icon documents it
  alongside the existing `⌘⇧'` keyboard-navigation shortcut.

## 4. Model name on each row — implemented

Sessions are launched with specific models (via aliases like `fable`, `opus`,
`sonnet`, `sol`, `terra`, `luna`), but rows don't say which model is running.

- Capture and persist the model from hook payloads, CLI flags in the zsh wrapper, and live context
  telemetry, including model changes during a session.
- Keep the provider logo and label each row with both the provider and a compact friendly model
  name; fall back to the provider name alone when the model is not yet knowable. This applies to
  active and Recent rows, while usage meters stay grouped under provider names.
- Stored model per session also enables attributing usage-meter burn to specific models later.

## 5. Token usage history chart — implemented

A daily/weekly view of total token usage as a stacked bar chart, one color per
model (falling back to the harness name when the model is unknown), with colors
grouped into families per provider so Claude/Codex/Cursor remain distinguishable
at a glance.

- Lives behind the existing usage-meters section at the bottom of the panel:
  collapsed by default, expanded with a disclosure control; toggle between
  per-day and per-week bars.
- Data sources: Claude Code transcripts record per-message `usage`
  (input/output/cache tokens) in `~/.claude/projects/**/*.jsonl`; Codex rollout
  files record running `total_token_usage` in `~/.codex/sessions/**/*.jsonl`.
  Cursor writes no token counts to any local file for CLI sessions (transcripts,
  chat stores, and the IDE state database were all checked), but its dashboard
  API exposes per-request usage events with a full token breakdown
  (input/output/cache-read/cache-write per model) — same
  `aiserver.v1.DashboardService` host and bearer credential the usage meters
  already use, so Cursor bars come from polling that endpoint instead.
- Aggregate into small per-day, per-model counters in SQLite; the transcript
  files are scanned in place and never stored, keeping the "no transcripts"
  guarantee.
- Count output plus fresh input tokens, showing cache reads separately or not
  at all — cached input dominates raw totals (a recent Codex session was 13M
  input tokens of which 12.9M were cache hits) and would swamp the chart.
