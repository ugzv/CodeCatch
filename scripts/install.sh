#!/bin/bash
# Tests, builds CodeCatch.app, installs it to ~/Applications and (re)launches it.
#   scripts/install.sh              test + build + install + launch
#   scripts/install.sh --no-launch  test + build + install only
#   scripts/install.sh --build-only test + build a universal app without installing
#   scripts/install.sh --release    test + build + notarized drag-to-Applications CodeCatch.dmg
#   scripts/install.sh --publish    --release, then upload the DMG as a GitHub release and push the feed
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
    ""|--no-launch|--build-only|--release|--publish) ;;
    *) echo "Usage: $0 [--no-launch|--build-only|--release|--publish]" >&2; exit 1 ;;
esac
# Published artifacts must correspond to a committed, reviewable source tree.
if [[ "${1:-}" = --release || "${1:-}" = --publish ]] && [ -n "$(git status --porcelain)" ]; then
    echo "Commit or remove local changes before releasing." >&2; exit 1
fi
# The release tags HEAD and the feed is pushed on top of it, so HEAD must be the pushed main.
if [ "${1:-}" = --publish ]; then
    git fetch --quiet origin main
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]; then
        echo "Check out main and push it before publishing." >&2; exit 1
    fi
fi
# The public history restarted at one commit after build 52 shipped; 100 keeps builds increasing.
VERSION="${CODECATCH_BUILD_NUMBER:-$(( $(git rev-list --count HEAD) + 100 ))}"
if ! [[ "$VERSION" =~ ^[1-9][0-9]{0,8}$ ]]; then
    echo "CODECATCH_BUILD_NUMBER must be a positive integer of at most nine digits." >&2; exit 1
fi
SOURCE_REVISION="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain)" ]; then SOURCE_REVISION="$SOURCE_REVISION-dirty"; fi
if [[ "${1:-}" = --release || "${1:-}" = --publish ]]; then
    PUBLISHED="$(sed -nE 's:.*<sparkle\:version>([0-9]+)</sparkle\:version>.*:\1:p' site/appcast.xml | sort -n | tail -1)"
    if [ -z "$PUBLISHED" ] && grep -q '<item' site/appcast.xml; then
        echo "Cannot read the published build number from site/appcast.xml." >&2; exit 1
    fi
    if [ -n "$PUBLISHED" ] && [ "$VERSION" -le "$PUBLISHED" ]; then
        echo "Build $VERSION must exceed published build $PUBLISHED; commit first or set CODECATCH_BUILD_NUMBER." >&2; exit 1
    fi
fi

scripts/test.sh --quiet --force-resolved-versions
# Own scratch dir: a release build in .build breaks the debug macro plugins `swift test` needs.
BUILD="${CODECATCH_BUILD_DIR:-.build-release}"
BUILD_ARGS=(--force-resolved-versions -c release --scratch-path "$BUILD" --arch arm64 --arch x86_64)
# The Command Line Tools stamp the binary as built with the deployment target's SDK (15.0),
# and macOS then gives it the pre-Liquid Glass look and behaviour. Stamp the SDK really used.
swift build "${BUILD_ARGS[@]}" -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$(xcrun --show-sdk-version)"
# Generated resources stay in scratch space; a build never changes the source tree.
swift scripts/make-icon.swift "$BUILD/AppIcon.icns"

APP="$BUILD/CodeCatch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/CodeCatch" "$APP/Contents/MacOS/"
for ARCH in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/CodeCatch" -verify_arch "$ARCH"
done
SPARKLE="$BUILD/artifacts/sparkle/Sparkle"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$FRAMEWORK"
cp Resources/Info.plist "$APP/Contents/"
# The build number tells installed builds apart; source revision identifies the checkout.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CodeCatchSourceRevision string $SOURCE_REVISION" "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"
# Liquid Glass icon (macOS 26+) needs Xcode's actool; without it the flat .icns is used.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
        --minimum-deployment-target 15.0 --output-partial-info-plist "$BUILD/AppIcon.plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
fi
# Developer ID: Keychain items and privacy grants name the team, so every rebuild
# keeps them. Override with CODECATCH_IDENTITY (any unique part of the name).
SIGN=(codesign --force --options runtime --timestamp --sign "${CODECATCH_IDENTITY:-Developer ID Application}")
# Inside out: notarization wants every Sparkle helper signed by us, before the app seals them.
"${SIGN[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"
"${SIGN[@]}" --identifier com.uros.codecatch "$APP"
codesign --verify --strict --deep "$APP"
if [ "${1:-}" = "--build-only" ]; then
    echo "Built $APP (not yet notarized)"
    exit 0
fi
if [ "${1:-}" = "--release" ] || [ "${1:-}" = "--publish" ]; then
    DMG="$BUILD/CodeCatch.dmg"
    swift scripts/make-dmg-background.swift "$BUILD/dmg-background.png"
    # dmgbuild writes the window layout itself, so no Finder scripting (or its permission prompt).
    uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg-settings.py -D app="$APP" -D icon="$BUILD/AppIcon.icns" -D background="$BUILD/dmg-background.png" CodeCatch "$DMG"
    "${SIGN[@]}" "$DMG"
    # Credentials: xcrun notarytool store-credentials codecatch --apple-id ... --team-id ...
    xcrun notarytool submit "$DMG" --keychain-profile "${CODECATCH_NOTARY_PROFILE:-codecatch}" --wait
    # The stapled ticket covers the app inside, so Gatekeeper passes it offline too.
    xcrun stapler staple "$DMG"
    # Sparkle feed: signs the DMG with the EdDSA key in the Keychain (generate_keys made it).
    # The DMG is a GitHub release asset; the feed is in git and CI deploys site/ on push.
    TAG="v$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist).$VERSION"
    rm -rf "$BUILD/release" && mkdir "$BUILD/release"
    cp "$DMG" "$BUILD/release/"
    "$SPARKLE/bin/generate_appcast" "$BUILD/release" --download-url-prefix "https://github.com/ugzv/CodeCatch/releases/download/$TAG/" \
        --full-release-notes-url https://codecatch.app/changelog/ -o site/appcast.xml
    if [ "${1:-}" = "--release" ]; then
        echo "Released $DMG; --publish uploads it"
        exit 0
    fi
    gh release create "$TAG" "$DMG" --repo ugzv/CodeCatch --target "$(git rev-parse HEAD)" \
        --title "CodeCatch $TAG" --notes "https://codecatch.app/changelog/"
    # Installed copies see the update once CI deploys the pushed feed.
    git commit --quiet -m "chore(release): $TAG" -- site/appcast.xml
    git push --quiet origin HEAD:main
    echo "Published $TAG"
    exit 0
fi

DEST="$HOME/Applications/CodeCatch.app"
pkill -x CodeCatch 2>/dev/null && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "Installed $DEST"
[ "${1:-}" = "--no-launch" ] || open "$DEST"
