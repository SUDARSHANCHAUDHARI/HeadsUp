# HeadsUp

![License](https://img.shields.io/badge/License-MIT-blue) ![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-13+-000000?logo=apple&logoColor=white) ![TypeScript](https://img.shields.io/badge/TypeScript-bun-3178C6?logo=typescript&logoColor=white)

> A floating robot head on your Mac that shows what Claude Code is doing right now.

HeadsUp is a small native macOS app. Claude Code hooks tell it what the agent is doing, and an animated robot head in a transparent always-on-top window shows it: thinking, searching, working, waiting for you, done, failed or asleep.

## Overview

When Claude Code runs in a terminal behind other windows, you cannot see at a glance whether it is still working, waiting for a permission, or finished. HeadsUp puts that status on screen as a small robot that sits above every app and every desktop space.

The robot is the drawing engine from [robot-heads](https://github.com/fayazara/robot-heads) by Fayaz Ahmed (MIT), used without React. HeadsUp adds the macOS window, the state file and the Claude Code hook.

## Features

- Nine robot states, each with its own LED face, motion and antenna light
- Transparent, borderless window that floats above all apps and appears on every desktop space
- Drag the head anywhere; the position is remembered between launches
- Right-click the head to quit; no Dock icon
- One hook script maps Claude Code events to states, always exits 0 and never blocks Claude
- Shows `happy` when a turn ends, then returns to `idle` after 5 seconds
- Eyes and head follow the pointer when it is near
- With macOS Reduce Motion on, shows still poses instead of animating
- No React, no npm install: the web part is bundled with `bun build`

## Screenshots

![HeadsUp showing the error state: a blue robot head with X eyes and a red antenna light](docs/screenshot.png)

The head in the `error` state, floating above the desktop.

## Installation

### From source

```bash
git clone https://github.com/SUDARSHANCHAUDHARI/HeadsUp.git
cd HeadsUp
./build.sh
```

### Requirements

- macOS 13 or newer
- Xcode command line tools (Swift 5.9 or newer)
- [bun](https://bun.sh), used only to bundle the TypeScript

## Usage

```bash
# start the app (the head appears bottom-right the first time)
.build/out/Products/Release/HeadsUp

# show a state by hand
echo thinking > ~/.headsup/state
```

If your Swift toolchain puts the binary elsewhere, `swift build -c release --show-bin-path` prints the folder.

## Configuration

Add this hook group to each of these events in `~/.claude/settings.json`: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `PermissionRequest`, `Stop`, `StopFailure`, `SessionEnd`. Use the absolute path to your clone.

```json
{ "matcher": "*", "hooks": [ { "type": "command", "command": "bash /path/to/HeadsUp/hooks/headsup-state.sh" } ] }
```

Open sessions keep their old hooks; new sessions pick this up.

## How It Works

```
Claude Code hook event (stdin JSON)
        │
        ▼
hooks/headsup-state.sh ──► ~/.headsup/state   (one word, written atomically)
                                   │
                                   ▼  read 4× a second
                      HeadsUp.app (NSPanel + WKWebView)
                                   │
                                   ▼  window.setState(word)
                      robot-heads renderer on a <canvas>
```

| Hook event | State |
|---|---|
| `UserPromptSubmit`, `PostToolUse` | thinking |
| `PreToolUse` for Read, Grep, Glob, WebSearch, WebFetch | searching |
| `PreToolUse` for any other tool | working |
| `Notification`, `PermissionRequest` | listening |
| `Stop` | happy, then idle after 5 s |
| `StopFailure` | error |
| `SessionEnd` | sleeping |

No state file yet means no session has run, so the head sleeps. Unknown events leave the state unchanged. With several sessions open, the last event wins.

## Development

```bash
./build.sh                          # bundle web/src with bun, copy into the Swift target, swift build -c release
swift build                         # debug build of the app only (run ./build.sh once first)

# feed the hook a sample event
printf '{"hook_event_name":"PreToolUse","tool_name":"Grep"}' | bash hooks/headsup-state.sh
cat ~/.headsup/state                # searching
```

## Project Structure

```
HeadsUp/
├── Package.swift                 # Swift package, bundles Resources/web
├── Sources/HeadsUp/main.swift    # window, web view, state-file polling, drag, quit menu
├── web/
│   ├── index.html                # transparent page with one <canvas>
│   └── src/
│       ├── main.ts               # plain-DOM wrapper, exposes window.setState
│       ├── ticker.ts, color.ts, types.ts
│       └── tv/                   # robot-heads renderer (geometry, faces, light, sim, render)
├── hooks/headsup-state.sh        # Claude Code hook: event → state file
└── build.sh
```

`web/src/tv/*`, `ticker.ts`, `color.ts` and `types.ts` are copied unchanged from robot-heads 0.3.0.

## Roadmap / Status

Working locally: all nine states render, the hook drives the head from a live Claude Code session, drag and quit work.

Not built yet: one head per session, start at login, a menu-bar menu, code signing.

## Tech Stack

- **App**: Swift, AppKit (`NSPanel`), WebKit (`WKWebView`)
- **Robot**: TypeScript on a 2D canvas, bundled with bun
- **Integration**: Claude Code hooks, Bash

The transparent background uses WKWebView's undocumented `drawsBackground` key; a future macOS could change it.

## Credits

The robot itself is not my work. The drawing engine comes from
[robot-heads](https://github.com/fayazara/robot-heads) 0.3.0 by
[Fayaz Ahmed](https://github.com/fayazara), used under the MIT licence.

These files are copied from it unchanged, and are the larger part of this repo
(1,946 of its 2,129 source lines):

- `web/src/tv/geometry.ts`, `faces.ts`, `light.ts`, `sim.ts`, `render.ts`
- `web/src/ticker.ts`, `web/src/color.ts`, `web/src/types.ts`

What HeadsUp adds is the macOS side: `Sources/HeadsUp/main.swift` (the
transparent always-on-top panel and the state-file polling),
`web/src/main.ts` (a plain-DOM wrapper replacing the original React one) and
`hooks/headsup-state.sh` (the Claude Code hook). If you like the robot, star
the original repo.

## License

MIT — see [LICENSE](LICENSE). Includes code from robot-heads, © 2026 Fayaz Ahmed, MIT.

---

## About

I'm Sudarshan Chaudhari, a Senior Quality Engineer, Test Automation specialist, and AI systems builder based in Bangkok, Thailand.

I have 13+ years of experience in software quality engineering, working across SaaS, fintech, gaming, web, mobile, cloud, and digital signage platforms. My background combines hands-on test automation with QA leadership, test strategy, CI/CD, release quality, production investigation, and cross-platform validation.

Alongside my professional QA career, I run [SudarshanTechLabs](https://sudarshantechlabs.com/), my independent engineering and product lab where I design, build, test, and ship software across Android, web, AI, cybersecurity, developer tooling, and cross-platform applications.

### What I work on

- ⚙️ **Quality Engineering & Test Automation** — Playwright, Selenium, Cypress, Appium, API testing, automation frameworks, end-to-end testing, CI/CD, release gates, GitHub Actions, risk-based testing, and production validation
- 🤖 **AI Systems & Automation** — AI agents, multi-agent orchestration, MCP servers, AI-assisted QA, prompt tooling, developer workflows, automation systems, and Claude Code plugins
- 📱 **Mobile & Cross-Platform Applications** — Android applications built with Kotlin and Jetpack Compose, Google Play releases, automated build and publishing pipelines, and cross-platform development spanning iOS, web, Windows, and macOS
- 🌐 **Web Applications & Platforms** — Full-stack applications using Next.js, TypeScript, Firebase, Cloudflare, REST APIs, and modern web infrastructure
- 🛠️ **Developer Tooling & CLI Engineering** — Rust, Python, TypeScript, CLI utilities, multi-repository tooling, build automation, release tooling, and engineering productivity systems
- 🛡️ **Cybersecurity & Observability** — Threat detection, log analysis, security auditing, vulnerability assessment, monitoring, and security-focused developer tools
- 📺 **Digital Signage & Device Platforms** — Content validation, playback testing, device compatibility, production investigation, monitoring, and QA across diverse hardware and operating-system environments

My work sits at the intersection of quality engineering, automation, AI, and software development. I approach products with a QA mindset from the beginning: understanding failure modes, designing for testability, automating repetitive work, and building release confidence into the engineering process.

Through SudarshanTechLabs, I also build products and tools from idea to production, covering architecture, development, testing, CI/CD, release automation, monitoring, and ongoing maintenance.

🌐 [sudarshantechlabs.com](https://sudarshantechlabs.com/) · 💼 [LinkedIn](https://linkedin.com/in/sudarshan-chaudhari) · 🐙 [GitHub](https://github.com/SUDARSHANCHAUDHARI) · ✉️ [sunny.sudarshan@gmail.com](mailto:sunny.sudarshan@gmail.com)
