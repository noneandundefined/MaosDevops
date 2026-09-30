#!/bin/bash
# Build on macOS with Xcode Command Line Tools / Xcode
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild \
  -project MaosDevops.xcodeproj \
  -scheme MaosDevOps \
  -configuration Release \
  -destination 'platform=macOS,arch=x86_64' \
  ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=10.15 \
  CODE_SIGNING_ALLOWED=NO \
  build
