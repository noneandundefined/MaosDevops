<p align="center">
  <img src="MaosDevops/Resources/Assets.xcassets/AppIcon.appiconset/appicon_256.png" width="144" alt="Maos DevOps icon">
</p>

<h1 align="center">Maos DevOps</h1>

<p align="center">
  A lightweight native DevOps workspace for managing Linux servers from older Intel Macs.
</p>

<p align="center">
  <a href="https://github.com/noneandundefined/MaosDevops/actions/workflows/build.yml"><img src="https://github.com/noneandundefined/MaosDevops/actions/workflows/build.yml/badge.svg" alt="Build status"></a>
  <a href="https://github.com/noneandundefined/MaosDevops/releases/latest"><img src="https://img.shields.io/github/v/release/noneandundefined/MaosDevops?display_name=tag" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-10.15%2B-111111?logo=apple" alt="macOS 10.15 or newer">
  <img src="https://img.shields.io/badge/architecture-Intel%20x86__64-3578e5" alt="Intel x86_64">
  <img src="https://img.shields.io/badge/UI-native%20AppKit-5ac8fa" alt="Native AppKit">
</p>

Maos DevOps brings SSH, server monitoring, Docker, systemd, logs, file transfer,
deployments and health checks into one native macOS application. It is designed
for machines that cannot run newer DevOps clients requiring macOS 12 or Apple
Silicon.

## Highlights

- **Native and lightweight** — Swift + AppKit, with no Electron or embedded browser.
- **Built for Catalina** — deployment target macOS 10.15 and Intel-only `x86_64` releases.
- **One SSH connection layer** — system OpenSSH with ControlMaster multiplexing and bounded concurrency.
- **Secure local storage** — credentials stay in macOS Keychain; SQLite stores only secret identifiers.
- **Operational workspace** — terminal, monitoring, Docker, systemd, logs, SFTP, Git and deploy workflows.
- **No remote service required** — servers and configuration are managed locally from the Mac.
- **Verified one-click updates** — downloads the release ZIP, checks SHA-256 and code signing, installs it and restarts the app without opening a browser.

## Features

| Area | Capabilities |
|---|---|
| Servers | Groups, favorites, password/key authentication, connection testing and live overview |
| Terminal | Persistent multi-tab SSH sessions, history, reconnect, copy/paste and bounded output |
| Monitoring | CPU, RAM, disk, load and network history with native 15m/1h/24h charts |
| Docker | Containers, stats, logs, shell, inspect, lifecycle controls and Compose operations |
| systemd | Service status, start/stop/restart, enable/disable and journal streaming |
| Logs | systemd, Docker, file and command streams with pause, search and filtering |
| Files | Lazy remote file tree, upload/download with progress, rename, delete, folders and a guarded UTF-8 text editor |
| Automation | Custom actions, quick actions, projects, deploy workflows and rollback actions |
| Git | Status, branches, history, diff, pull, fetch and ahead/behind information |
| Health checks | Scheduled HTTP, TCP and remote shell checks with latency and status |

The complete implementation review is maintained in
[`docs/TZ_CHECKLIST.md`](docs/TZ_CHECKLIST.md).

## Requirements

- macOS Catalina 10.15 or newer
- Intel Mac (`x86_64`)
- SSH access to one or more Linux servers
- Approximately 4 GB RAM or more recommended

Docker and systemd controls are shown only when the selected remote server
provides those services.

## Download and install

1. Open the [latest release](https://github.com/noneandundefined/MaosDevops/releases/latest).
2. Download `MaosDevOps-macOS-10.15-Intel.dmg`.
3. Open the DMG and drag **Maos DevOps** into **Applications**.
4. On first launch, right-click the app and choose **Open** if macOS shows a Gatekeeper warning.

Public builds are ad-hoc signed. SHA-256 checksums are published with every
release as `SHA256SUMS.txt`.

## Build from source

Open the project in Xcode:

```bash
open MaosDevops.xcodeproj
```

Or build an unsigned Intel Release app from Terminal:

```bash
bash Scripts/build.sh
```

Create the same ZIP and DMG artifacts used by GitHub Actions:

```bash
APP_VERSION=0.2.4 BUILD_NUMBER=1 bash Scripts/package.sh
```

The packaging script validates the final Mach-O architecture, minimum macOS
version, application bundle and ad-hoc signature before producing artifacts.
On an interactive Mac, set `RUN_LAUNCH_SMOKE_TEST=1` to additionally launch the
built application and verify its main-window lifecycle before packaging.

## GitHub Actions releases

Every push and pull request runs an Intel macOS build. Tags matching `v*`
additionally publish a GitHub Release containing:

- `MaosDevOps-macOS-10.15-Intel.dmg`
- `MaosDevOps-macOS-10.15-Intel.zip`
- `SHA256SUMS.txt`

## Security model

- Passwords and key passphrases are stored only in macOS Keychain.
- SQLite stores a Keychain reference, never plaintext credentials.
- SSH uses the OpenSSH client provided by macOS.
- Command, terminal and log buffers are bounded to avoid unbounded memory growth.
- Dangerous and destructive actions require explicit confirmation.

## Project structure

```text
MaosDevops/
├── App/          Application lifecycle and shared services
├── Servers/      Server management and overview
├── SSH/          OpenSSH connection and command execution
├── Terminal/     Persistent interactive sessions
├── Monitoring/   Metrics collection and charts
├── Docker/       Container and Compose operations
├── Systemd/      Service management
├── Logs/         Bounded live log streams
├── Files/        SFTP browser and editor
├── Actions/      Custom and quick actions
├── Projects/     Projects and deploy workflows
├── Git/          Remote repository operations
├── Storage/      SQLite persistence
├── Keychain/     Secure credential storage
└── Resources/    Info.plist, entitlements and app icon
```

The application keeps business logic in service and controller types rather
than placing remote operations directly in view controllers.

## Catalina verification

CI verifies compilation with the current Xcode toolchain, an Intel-only
executable and a Mach-O minimum OS of 10.15. Before a stable production release,
the interface, Keychain and SSH flows should also be smoke-tested on a real Mac
running macOS Catalina 10.15.7.
