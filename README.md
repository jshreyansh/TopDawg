# TopDawg

> Your Claude command center, living in the notch.

TopDawg is a macOS app that turns the MacBook Pro notch into a full-featured control panel for Claude. Track every running session, chat with Claude directly from the notch, intercept and approve tool calls before they run, capture notes, monitor system health, and stay on top of your Claude.ai usage — all without breaking your flow.

---

## What it looks like

The notch bar collapses to a slim strip showing your live Claude usage. Hover or press `Ctrl+Option+C` and it expands into an 8-panel command center:

```
┌─────────────────── notch ────────────────────┐
│  45% ↑  ·  Claude Code  ·  3 running   44% ↑  │  ← collapsed bar (always visible)
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│  ≡  Sessions │ Chat │ Notes │ Stats │ …      │  ← expanded panel (290px tall)
│                                              │
│  claude code                                 │
│  ● shreyansjaiswal    2s ago   ⟳             │
│  ● TopDawg            5m ago                 │
│                                              │
│  claude desktop                              │
│  ○ claude desktop     12m ago               │
└──────────────────────────────────────────────┘
```

---

## Features

### Sessions Panel

Discovers and lists every Claude session running on your Mac, in real time, grouped by surface:

| Type | How it's found |
|---|---|
| **Claude Code CLI** | Scans `~/.claude/sessions/*.json`, cross-checks with live process table |
| **Claude Desktop** | NSWorkspace bundle ID lookup |
| **Cowork agents** | `~/Library/Application Support/Claude/local-agent-mode-sessions/` |

Each row shows the session title (last user message or cwd), time since last activity, and whether Claude is actively processing or idle at the prompt.

**Click a session** → TopDawg walks the process tree from the `claude` PID to its owning terminal app (Terminal, iTerm2, Ghostty, Warp, VS Code, Cursor, Windsurf, …) and brings that window to the front.

**Click `+`** → launches a brand-new `claude` session. Opens a new tmux window if a tmux server is running, otherwise opens a Terminal.app tab.

---

### Chat Panel

Open any session row to get a live chat window inside the notch — no switching apps.

**Live transcript streaming**: watches the session's JSONL file via `DispatchSource` and incrementally appends new content as Claude writes it. Works even before the first message (polls every 0.5 s until the file is created).

**Renders every message type:**
- User messages — right-aligned coral bubbles
- Assistant text — left-aligned with inline Markdown rendering
- Thinking blocks — collapsible, shows first 40 chars inline
- Tool calls — amber chips with expandable JSON input
- Tool results — success/error badge with output preview
- Token usage — per-message and running session total

**Message sending** uses a three-tier strategy, trying each in order:

1. **tmux `send-keys`** — completely silent, no clipboard touch, no window activation. Used when the session is inside a tmux pane.
2. **Terminal.app AppleScript** — finds the exact tab by its tty device path and calls `do script … in tab`. No Accessibility permission needed.
3. **CGEvent clipboard paste** — activates the terminal, pastes via `Cmd+V`, sends `Return`. Requires Accessibility permission. Clear error shown if permission is missing.

---

### Approvals Panel

When Claude Code's permission hook fires (e.g., before running a Bash command or writing a file), TopDawg intercepts it and shows a native approval overlay — without you having to watch the terminal.

**How it works:**

TopDawg runs a local HTTP server on a random port. On first launch (and whenever the port changes), it writes the hook URL into `~/.claude/settings.json` automatically. Every time Claude Code needs permission, it POSTs to TopDawg instead of the default stdin prompt.

The approval overlay shows:
- Tool name and icon (`Bash`, `Edit`, `Write`, `WebFetch`, MCP tool names, …)
- Best-effort headline: extracts the shell command for Bash, the filename for Edit/Write, the URL for WebFetch
- Working directory context
- Full detail preview (command body, file path + content snippet, or raw JSON)

**Three choices:**
- **Allow** — approve this request once
- **Allow Always** — approve and write a permanent rule to Claude Code's settings so you're never asked again for this pattern
- **Deny** — reject; Claude Code receives a denial and stops the tool call

Auto-denies after 120 seconds if left unanswered.

---

### Stats Panel

Live Claude.ai usage at a glance:

- **Session %** — usage in the current 5-hour rolling window
- **Weekly %** — usage in the current 7-day window
- **Model breakdowns** — Sonnet, Opus, and other models tracked separately
- **Burn rate** — %/hr, so you can see if you're on track to hit the limit
- **Sparklines** — 30-point rolling history for both session and weekly usage
- **Smart alerts** — orange warning above 75%, red critical when on track to exhaust before reset

---

### Analytics Panel

Forecast mode. For each usage window:
- Current % + status chip (OK / At risk / Exhausted)
- Zoned forecast bar with color bands (green → yellow → orange → red)
- Projected % at window reset
- "Full at HH:MM" countdown for critical states
- Pace ratio: how fast you're burning relative to even pacing

Updates every 10 seconds.

---

### Focus Timer

A Pomodoro timer that lives inside the notch:

- **Configurable durations**: work (default 25 min), short break (5 min), long break (15 min)
- **4-session cycle**: work → short break → work → short break → work → short break → work → long break, then repeat
- **Visual progress bar**: coral during work, teal during breaks, red when under 2 minutes
- **Native notifications** when each phase completes
- **Controls**: play/pause, skip phase, reset

---

### System Monitor

Real-time CPU and RAM without opening Activity Monitor:

- CPU usage % with color-coded gauge (green < 50%, yellow < 70%, orange < 85%, red above)
- RAM used / total in GB
- 30-point history sparklines for both
- Updates every 2 seconds via Darwin host APIs (`host_processor_info`, `host_statistics64`)

---

### Notes

A quick capture layer for anything that comes up while you're working:

- **Text notes**: first line becomes the title
- **Link notes**: paste or drop a URL and TopDawg fetches the page title, description, image, and favicon automatically
- **Drag & drop**: accepts URLs, plain text, and file references from any app
- **Stored locally**: `~/Library/Application Support/TopDawg/Notes/`

---

## Setup

### Build from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
git clone <this-repo> TopDawg && cd TopDawg
xcodegen generate
xcodebuild -project TopDawg.xcodeproj -scheme TopDawg -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/TopDawg-*/Build/Products/Debug/TopDawg.app
```

Or open `TopDawg.xcodeproj` directly in Xcode and hit **Run**.

### First launch

1. **Log in to Claude.ai** via the setup wizard (needed for Stats and Analytics; Sessions and Chat work without it).
2. **Grant Accessibility** when prompted — required to bring terminal windows to the front and as a fallback for message sending. `System Settings → Privacy & Security → Accessibility → TopDawg`.
3. **Hover the notch** or press `Ctrl+Option+C` — the panel opens. Default tab is Sessions.

---

## Keyboard shortcut

| Shortcut | Action |
|---|---|
| `Ctrl + Option + C` | Toggle panel open/close from anywhere |

---

## Settings

| Setting | Options |
|---|---|
| Size preset | Small / Medium / Large / Extra Large (affects wing width) |
| Pacing display | % only · % + arrow · % + arrow + time to reset |
| Auto-refresh interval | 1 / 2 / 5 / 10 / 15 / 30 minutes |
| Alert threshold | Off · 80% · 90% · 95% |
| Timer durations | Configurable work / short break / long break |
| Launch at login | On / Off |
| Display | Multi-monitor selector |

---

## Architecture notes

- **Window level**: `.screenSaver` — floats above all other windows, never obscured
- **Notch geometry**: auto-detected via `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; gracefully falls back on non-notch displays
- **No sandbox**: required to read `~/.claude/`, walk process trees, and use Accessibility
- **Session state**: reads `~/.claude/sessions/*.json` for CLI sessions and cross-checks PIDs with the live process table; watches JSONL transcripts with `DispatchSource` for processing state
- **Approval server**: local HTTP on a random port; token-authenticated; hook URLs auto-written to `~/.claude/settings.json`
- **Message sending**: tmux → AppleScript → CGEvent, in that order

---

## Terminal compatibility

TopDawg can focus and send messages to sessions running in:

Terminal.app · iTerm2 · Ghostty · WezTerm · Alacritty · Warp · Kitty · Tabby · Hyper · VS Code · Cursor · Windsurf

---

## License

MIT — see `LICENSE`.
