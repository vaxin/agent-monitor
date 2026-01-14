# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

IPMonitor is a macOS menu bar application (Swift) that displays your current public IP address and geolocation information. It fetches data from ipinfo.io every 60 seconds and shows a color-coded country badge in the system tray.

## Build Commands

```bash
# Build release
swift build -c release

# Build debug
swift build

# Run (debug)
swift run

# Run release binary directly
.build/arm64-apple-macosx/release/IPMonitor
```

## Architecture

Single-file AppKit application (`Sources/main.swift`) with:

- **IPInfo struct**: Data model for IP/geo information
- **AppDelegate**: Main app controller handling:
  - Menu bar status item with color-coded country badge
  - Detail window with request/location info cards
  - 60-second auto-refresh timer + manual refresh
  - ipinfo.io API integration via URLSession

The app embeds Info.plist via linker flags (see Package.swift) to register as a proper macOS application.

## Country Color Coding

- US → Green
- CN → Red
- Other → Orange
- Error/Unknown → Gray
