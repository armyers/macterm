#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
BUILD_DIR="$PROJECT_ROOT/build"
# Local builds (mise run build/ship/install) leave VERSION unset; derive a
# meaningful, monotonic version from the commit count (e.g. 1.0.338) so each
# install is distinguishable in About/Settings instead of a static 0.0.0.
# Tagged releases set VERSION explicitly (.github/workflows/release.yml), so
# they're unaffected.
if [[ -z ${VERSION:-} ]]; then
  COMMIT_COUNT=$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2> /dev/null || echo 0)
  VERSION="1.0.${COMMIT_COUNT}"
fi
# Sparkle compares CFBundleVersion against the appcast's sparkle:version when
# deciding whether an update is newer. Use the marketing string for both so a
# new tag always wins — a raw commit count can stay equal across two
# consecutive tags built from the same commit and trip "You're up to date".
BUILD_NUMBER="$VERSION"
GIT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2> /dev/null || echo "unknown")
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-SPARKLE_ED_PUBLIC_KEY_PLACEHOLDER}"
DMG_NAME="Macterm-${VERSION}.dmg"
DERIVED_DATA="$BUILD_DIR/DerivedData"
ARCHIVE_PATH="$BUILD_DIR/Macterm.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# Ensure GhosttyKit + bundled resources (themes, shell-integration) are present
# before xcodegen resolves the folder references. Idempotent; no-op in CI where
# ci:setup already ran.
"$PROJECT_ROOT/scripts/setup.sh"

# Regenerate the Xcode project so any project.yml edits land in CI builds
# without requiring a developer to commit the generated .xcodeproj.
xcodegen generate --spec "$PROJECT_ROOT/project.yml" > /dev/null

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

# Code-signing identity. The project default is ad-hoc ("-"), which gives a
# fresh signature on every build — so macOS keeps re-prompting for TCC
# permissions (Downloads, Full Disk Access, …). Set MACTERM_SIGN_IDENTITY to a
# stable cert (e.g. a self-signed "CYOTE-arm Dev" Code Signing cert in Keychain)
# to sign with a consistent identity so those grants persist across rebuilds.
# Unset → ad-hoc as before. The export step below uses signingStyle=manual and
# doesn't re-sign, so the archive's signature carries into the exported app.
SIGN_ARGS=()
if [[ -n ${MACTERM_SIGN_IDENTITY:-} ]]; then
  SIGN_ARGS+=("CODE_SIGN_IDENTITY=$MACTERM_SIGN_IDENTITY")
fi

# Archive: Xcode handles universal binary arch ($(ARCHS_STANDARD) is
# arm64+x86_64 in Release), embeds Sparkle.framework, signs everything
# (including Sparkle's XPC services) with the configured identity, and
# substitutes our Info.plist build-setting tokens.
xcodebuild \
  -project Macterm.xcodeproj \
  -scheme Macterm \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GIT_COMMIT="$GIT_COMMIT" \
  SPARKLE_ED_PUBLIC_KEY="$SPARKLE_ED_PUBLIC_KEY" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  archive \
  | (xcbeautify --quiet 2> /dev/null || cat)

# Copy the .app straight out of the archive. We ship ad-hoc-signed, so there's
# nothing to re-sign or notarize — the archive's Products/Applications already
# holds the fully-built, signed bundle (Sparkle and its XPC services included).
# `ditto` (not cp) preserves the framework symlinks a valid macOS bundle needs.
#
# This deliberately avoids `xcodebuild -exportArchive`: its `-exportOptionsPlist`
# `method` value is unstable across Xcode releases (Apple renamed the macOS
# export methods in Xcode 16, breaking the old `mac-application` value — the
# failure that motivated this). A direct copy has no version-sensitive tokens.
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Macterm.app"
if [[ ! -d $ARCHIVED_APP ]]; then
  echo "ERROR: $ARCHIVED_APP not found in archive" >&2
  exit 1
fi
mkdir -p "$EXPORT_PATH"
ditto "$ARCHIVED_APP" "$EXPORT_PATH/Macterm.app"

APP_BUNDLE="$EXPORT_PATH/Macterm.app"
# Sanity-check the copy is a valid, signed bundle before building a DMG from it.
if ! codesign --verify --deep --strict "$APP_BUNDLE" 2> /dev/null; then
  echo "ERROR: exported $APP_BUNDLE failed code-signature verification" >&2
  exit 1
fi

# Package into a compressed DMG with an Applications symlink for drag-install.
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$BUILD_DIR/$DMG_NAME"
hdiutil create -volname "Macterm" -srcfolder "$DMG_STAGING" -ov -format UDZO "$BUILD_DIR/$DMG_NAME"
rm -rf "$DMG_STAGING"

echo "Done: build/$DMG_NAME"
