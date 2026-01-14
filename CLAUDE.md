# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Agent Monitor is a macOS menu bar application (Swift) for monitoring AI agent sessions. It monitors Claude Code lifecycle events via FSEvents and displays active sessions in a floating panel.

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

- **SessionInfo struct**: Data model for agent session state
- **AppDelegate**: Main app controller handling:
  - Menu bar status item
  - Floating session list panel (frosted glass style)
  - FSEvents-based file monitoring for `~/.claude/logs/lifecycle/`
  - macOS notifications when agents complete

The app embeds Info.plist via linker flags (see Package.swift) to register as a proper macOS application.

## Session Status

- Working (green) - Agent is processing
- Waiting (yellow) - Agent finished, waiting for user input
- Ended - Session closed (hidden from list)
