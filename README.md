# Agent Monitor

A macOS menu bar application for monitoring AI agents running on your machine.

## Why?

Modern AI-assisted development often involves running multiple agent sessions concurrently:
- Multiple Claude Code sessions across different projects
- Background agents handling automated tasks
- Long-running code generation or analysis jobs

**The problem**: When you have 5+ agent sessions running, it's hard to know which ones need your attention and which are still working.

**The solution**: Agent Monitor provides a floating status window that shows all active sessions at a glance:
- 🟢 **Working** - Agent is processing
- 🟡 **Waiting** - Agent finished, waiting for your input

This lets you maximize concurrency by quickly switching to sessions that need you, while letting others continue working in the background.

## Features

- **Menu Bar App**: Unobtrusive system tray presence with country badge
- **Floating Status Window**: Always-on-top, translucent session list
- **Real-time Updates**: FSEvents-based file monitoring for instant status changes
- **macOS Notifications**: Alerts when agents complete tasks and await input
- **IP Monitor**: Shows your current public IP and geolocation (via ipinfo.io)

## Screenshot

![Agent Monitor](effect.png)

## Installation

### Quick Install (Lifecycle Hook Only)

If you just want the Claude Code lifecycle monitoring without the GUI app:

```bash
curl -fsSL https://raw.githubusercontent.com/vaxin/agent-monitor/main/install.sh | bash
```

This installs the lifecycle hook that logs all Claude Code events to `~/.claude/logs/lifecycle/`.

### Build from Source

Requirements: macOS 13+, Swift 5.9+

```bash
git clone https://github.com/vaxin/agent-monitor.git
cd agent-monitor
swift build -c release
.build/release/AgentMonitor
```

### Create App Bundle

```bash
swift build -c release
mkdir -p AgentMonitor.app/Contents/MacOS
cp .build/release/AgentMonitor AgentMonitor.app/Contents/MacOS/
cp Info.plist AgentMonitor.app/Contents/
```

## Configuration

After installing the lifecycle hook, enable it in Claude Code:

1. Open Claude Code settings: `claude config edit`
2. Add the hooks configuration:

```json
{
  "hooks": {
    "SessionStart": ["~/.claude/hooks/lifecycle-monitor.sh SessionStart"],
    "SessionEnd": ["~/.claude/hooks/lifecycle-monitor.sh SessionEnd"],
    "Stop": ["~/.claude/hooks/lifecycle-monitor.sh Stop"],
    "SubagentStop": ["~/.claude/hooks/lifecycle-monitor.sh SubagentStop"],
    "UserPromptSubmit": ["~/.claude/hooks/lifecycle-monitor.sh UserPromptSubmit"],
    "PreToolUse": ["~/.claude/hooks/lifecycle-monitor.sh PreToolUse"],
    "PostToolUse": ["~/.claude/hooks/lifecycle-monitor.sh PostToolUse"],
    "PreCompact": ["~/.claude/hooks/lifecycle-monitor.sh PreCompact"],
    "Notification": ["~/.claude/hooks/lifecycle-monitor.sh Notification"],
    "PermissionRequest": ["~/.claude/hooks/lifecycle-monitor.sh PermissionRequest"]
  }
}
```

## Log Files

The lifecycle hook writes to:
- `~/.claude/logs/lifecycle/all-events.jsonl` - All events in JSONL format (used by the GUI)
- `~/.claude/logs/lifecycle/session-{id}.log` - Per-session human-readable logs

## Usage

- **Left-click** tray icon: Toggle session monitor window
- **Right-click** tray icon: Show menu (IP info, refresh, clean sessions, quit)
- **Click session**: Select/highlight session
- **Double-click session**: Activate corresponding iTerm2 tab
- **Click trash icon**: Remove session from list

## Roadmap

- [ ] Support for other AI agents (Cursor, Aider, etc.)
- [ ] Cross-platform support (Linux, Windows)
- [ ] Web dashboard for remote monitoring
- [ ] Aggregated statistics and analytics

## License

MIT
