#!/bin/bash
# `swift test`, loading the Swift Testing macro plugin explicitly: with only the
# Command Line Tools installed its lookup is flaky ("plugin for module
# 'TestingMacros' not found" on alternate runs).
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then
    exec swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi
exec swift test "$@"
