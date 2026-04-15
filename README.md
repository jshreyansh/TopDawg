# TopDawg

A macOS notch-based command center for Claude. See every running Claude session (Claude Code CLI, Cowork, Desktop app) in one place, jump to any of them with a click, and keep tabs on your Claude.ai usage without leaving your current window.

Forked and reshaped from [acenaut/claude-notch](https://github.com/acenaut/claude-notch) (which was itself a fork of [carlomatthaei/claude-notch](https://github.com/carlomatthaei/claude-notch) — credit for the original notch-window plumbing, usage-API client, and Pomodoro timer goes to them).

## What's new vs. upstream

- **Sessions panel** (primary): live list of every Claude session running on this Mac, grouped by surface (Code / Desktop / Cowork), click-to-focus the owning terminal or app
- **Reads**:
  - `~/.claude/sessions/*.json` + `~/.claude/history.jsonl` (CLI)
  - `~/Library/Application Support/Claude/local-agent-mode-sessions/**/*.json` (Cowork)
  - `ps` + `NSWorkspace` for the Desktop app process
- **Focus mechanics**: walks the parent-process chain from the `claude` PID to find the owning terminal app (Terminal / iTerm / Ghostty / Warp / VS Code / Cursor / …) and activates it
- **Auto-updater disabled** (upstream pointed at a third-party repo; re-enable only after wiring your own release pipeline)
- **Sandbox disabled** (required to read outside the app container and use Accessibility)

Panels retained from upstream: **Stats**, **Analytics**, **Focus Timer**, **About**.
Panels hidden (still in enum, just dropped from the tab bar): System Monitor, Notes.

## Build & run

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone <this-repo-url> TopDawg
cd TopDawg
xcodegen generate
xcodebuild -project TopDawg.xcodeproj -scheme TopDawg -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/TopDawg-*/Build/Products/Debug/TopDawg.app
```

Or open `TopDawg.xcodeproj` in Xcode and hit Run.

## First launch

1. macOS will ask for **Accessibility** when you first click a session row — enable it in System Settings → Privacy & Security → Accessibility. This is what lets TopDawg focus other apps' windows.
2. Log in to Claude.ai via the built-in setup wizard (only needed for the Stats / Analytics panels; Sessions works without it).
3. Hover the notch — the dropdown opens. Default tab is **Sessions**.

## Hotkey

`Ctrl + Option + C` — toggle the panel from anywhere.

## Roadmap (not yet shipped)

- **v2** — Per-session actions: kill, copy session ID, reveal cwd in Finder, send `/clear` or `/compact` via Accessibility keystrokes
- **v3** — `topdawg run` wrapper that owns a Unix socket, enabling reliable typing-from-notch into wrapped CLI/Cowork sessions
- **v4** — Desktop app integration via Chrome DevTools Protocol (if Anthropic exposes a debug port)

## License

Same as upstream — see `LICENSE`.
