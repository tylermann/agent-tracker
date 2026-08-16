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

## 4. Model tag on each row

Sessions are launched with specific models (via aliases like `fable`, `opus`,
`sonnet`, `sol`, `terra`, `luna`), but rows don't say which model is running.

- Capture the model at session start when it is knowable (hook payload,
  CLI flags from the zsh wrapper, or harness settings).
- Show a compact model badge on each row next to the provider logo.
- Stored model per session also enables attributing usage-meter burn to
  specific models later.

## 5. Personal attention-latency stats

A small stats view answering "is this app actually saving me time":

- Per repo and per model, per week: agent working time vs. time spent blocked
  waiting on a human.
- Median response time to permission prompts and feedback requests.
- Highlights which repositories' agents starve the longest before getting
  attention.
