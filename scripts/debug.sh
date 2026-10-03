#!/bin/bash
# Build, sign and run the debug binary: `scripts/debug.sh --probe`.
# Signed like the release (Developer ID, same identifier), it satisfies the
# Keychain items' team rule, so rebuilds stop asking for the login password.
# Without that identity the binary stays unsigned and macOS prompts per item.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=.build/debug/CodeCatch
IDENTITY="${CODECATCH_IDENTITY:-Developer ID Application}"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --timestamp=none --sign "$IDENTITY" --identifier com.uros.codecatch "$BIN"
fi
exec "$BIN" "$@"
