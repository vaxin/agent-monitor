# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Agent Monitor is a macOS menu bar application (Swift) with two main features:

1. **Session Monitor**: Monitors Claude Code lifecycle events via FSEvents and displays active sessions in a floating panel
2. **IP Monitor**: Displays your current public IP address and geolocation information (via ipinfo.io)

## Build Commands

```bash
# Build release
swift build -c release

# Build debug
swift build

# Run (debug)
swift run

# Run release binary directly
.build/arm64-apple-macosx/release/AgentMonitor
```

## Architecture

Single-file AppKit application (`Sources/main.swift`) with:

- **IPInfo struct**: Data model for IP/geo information
- **SessionInfo struct**: Data model for agent session state
- **AppDelegate**: Main app controller handling:
  - Menu bar status item with color-coded country badge
  - IP Info window with request/location cards
  - Floating session list panel (frosted glass style)
  - FSEvents-based file monitoring for `~/.claude/logs/lifecycle/`
  - macOS notifications when agents complete
  - 60-second auto-refresh timer for IP

The app embeds Info.plist via linker flags (see Package.swift) to register as a proper macOS application.

## Session Status

- Working (green) - Agent is processing
- Waiting (yellow) - Agent finished, waiting for user input
- Ended - Session closed (hidden from list)

## Country Color Coding

- US → Green
- CN → Red
- Other → Orange
- Error/Unknown → Gray

## iTerm2 Integration

Double-clicking a session activates the corresponding iTerm2 tab:
1. Finds claude process with matching `cwd`
2. Gets process TTY via `ps`
3. Activates iTerm2 tab with matching TTY via AppleScript
