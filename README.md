<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Codex Island</h3>
  <p align="center">
    A macOS menu bar app that brings Dynamic Island-style notifications to Codex CLI sessions.
    <br />
    <br />
    <a href="https://github.com/NewmanXBT/codex-island/releases/latest" target="_blank" rel="noopener noreferrer">
      <img src="https://img.shields.io/github/v/release/NewmanXBT/codex-island?style=rounded&color=white&labelColor=000000&label=release" alt="Release Version" />
    </a>
    <a href="#" target="_blank" rel="noopener noreferrer">
      <img alt="GitHub Downloads" src="https://img.shields.io/github/downloads/NewmanXBT/codex-island/total?style=rounded&color=white&labelColor=000000">
    </a>
  </p>
</div>

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple Codex sessions in real-time
- **Codex-Aware Activity** — Follow session state, tool activity, and attention moments from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Codex monitoring installs automatically on first launch

## Requirements

- macOS 15.6+
- Codex CLI

## Install

Download the latest release or build from source:

```bash
xcodebuild -scheme ClaudeIsland -configuration Release build
```

## How It Works

Codex Island monitors Codex sessions using Codex telemetry plus transcript-backed session parsing. The app listens for activity and displays it in the notch overlay.

When Codex is processing, waiting for input, or calling tools, the notch surfaces those state changes without forcing a terminal switch.

## Analytics

Codex Island uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new Codex session is detected

No personal data or conversation content is collected.

## License

Apache 2.0
