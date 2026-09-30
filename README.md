# MaosDevOps

Lightweight native macOS DevOps client (AppKit + Swift).

**Target:** macOS 10.15 Catalina, Intel x86_64, ~4 GB RAM  
**Stack:** Swift + AppKit (no Electron, no SwiftUI as UI foundation)

## Implemented foundation

1. Servers + Keychain secrets + SQLite storage  
2. SSH connect / exec (system `ssh` + ControlMaster multiplexing)  
3. Multi-tab persistent SSH terminal  
4. Custom Actions (Command / Poll / Stream / Check / Group)  
5. Monitoring charts, systemd, Docker, bounded live logs, full SFTP file operations, Projects, Deploy, Git and Health Checks

The detailed implementation status against the product specification is in
[`docs/TZ_CHECKLIST.md`](docs/TZ_CHECKLIST.md). Items marked partial or planned
are not represented as complete features.

## Open & build on Mac

```bash
open MaosDevops.xcodeproj
```

Or build an unsigned Intel Release app from CLI:

```bash
bash Scripts/build.sh
```

Deployment target is **macOS 10.15**. Do not raise it.

Create release artifacts (`.zip`, `.dmg`, and `SHA256SUMS.txt`):

```bash
APP_VERSION=0.1.0 BUILD_NUMBER=1 bash Scripts/package.sh
```

GitHub Actions uses an Intel macOS runner, compiles with `ARCHS=x86_64`, checks
the finished Mach-O minimum OS, signs ad-hoc, uploads artifacts, and publishes
them for tags matching `v*`.

## Architecture

```
MaosDevops/
  App/          UI/           Servers/     SSH/
  Terminal/     Docker/       Systemd/     Logs/
  Monitoring/   Actions/      Deploy/      Files/
  Git/          Projects/     Storage/     Keychain/
  Models/       Utilities/
```

Business logic lives in service/controller classes — not in ViewControllers.

## Secrets

SSH passwords and passphrases are stored only in macOS Keychain.  
SQLite keeps secret identifiers, never plaintext secrets.
