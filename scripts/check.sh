#!/bin/zsh
# Zero-baseline quality gate: build, parallel tests (including architecture
# boundary tests), and localization completeness check.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" ]] \
        && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        echo "[check] Using Xcode toolchain via DEVELOPER_DIR=$DEVELOPER_DIR"
    fi
fi

echo "[check] 1/3 swift build"
swift build

echo "[check] 2/3 swift test (parallel)"
swift test

echo "[check] 3/3 scripts/check-localization.sh"
LOC_OUT="$(./scripts/check-localization.sh)"
echo "$LOC_OUT"
if ! print -r -- "$LOC_OUT" | grep -q "0 missing translations"; then
    echo "[check] FAIL: missing translations detected." >&2
    echo "[check] Fix: add missing keys to Localization/zh-Hans.lproj/Localizable.strings and Localization/en.lproj/Localizable.strings." >&2
    exit 1
fi

echo "[check] PASS: build, tests, boundaries, and localization all green."
