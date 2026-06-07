#!/usr/bin/env bash
#
# Run the PoseDeck M2 XCUITest suite against the local PocketBase dev backend.
#
# Prerequisites (see ../../STATUS.md):
#   - Backend up:   cd ../../backend && POSEDECK_DEV=true ./pocketbase serve --http=127.0.0.1:8090
#   - A booted "iPhone 16 Pro" simulator (xcrun simctl boot "iPhone 16 Pro").
#
# Why the flags below:
#   - The app persists its auth session to the Keychain. An unsigned simulator
#     build (CODE_SIGNING_ALLOWED=NO) has no entitlements, so Keychain writes
#     fail with errSecMissingEntitlement (-34018). We therefore AD-HOC SIGN
#     (CODE_SIGN_IDENTITY=-) so the keychain-access-group entitlement applies.
#   - typeText hangs if the Simulator's hardware keyboard is linked; we unlink it.
#   - The image-upload test needs a photo in the library; we seed one.
#
# Usage:
#   ./run-uitests.sh                 # whole suite
#   ./run-uitests.sh AuthUITests     # one test class
#   ./run-uitests.sh AuthUITests/testSignInSucceeds   # one test
set -euo pipefail

cd "$(dirname "$0")"

DEVICE="iPhone 16 Pro"
DD=/tmp/posedeck-dd
RESULT=/tmp/posedeck-uitests.xcresult

ONLY=""
if [[ $# -ge 1 ]]; then
  ONLY="-only-testing:PoseDeckUITests/$1"
fi

# 1. Unlink the hardware keyboard so software-keyboard typeText is reliable.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false || true

# 2. Make sure the target device is booted.
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || xcrun simctl boot "$DEVICE" || true

# 3. Seed a photo for the image-upload test (idempotent enough for dev).
SEED=/tmp/seed.jpg
if [[ ! -f "$SEED" ]]; then
  SRC=$(find /System/Library/Desktop\ Pictures -name "*.heic" 2>/dev/null | head -1)
  [[ -n "$SRC" ]] && sips -s format jpeg -z 480 640 "$SRC" --out "$SEED" >/dev/null 2>&1 || true
fi
[[ -f "$SEED" ]] && xcrun simctl addmedia "$DEVICE" "$SEED" || true

# 4. Regenerate the project (xcodeproj is gitignored) and build.
xcodegen generate >/dev/null

SIGN_FLAGS=(CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES)

xcodebuild -project PoseDeck.xcodeproj -scheme PoseDeck \
  -destination "platform=iOS Simulator,name=$DEVICE,arch=arm64" \
  -derivedDataPath "$DD" build-for-testing "${SIGN_FLAGS[@]}"

rm -rf "$RESULT"
xcodebuild -project PoseDeck.xcodeproj -scheme PoseDeck \
  -destination "platform=iOS Simulator,name=$DEVICE,arch=arm64" \
  -derivedDataPath "$DD" test-without-building "${SIGN_FLAGS[@]}" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -resultBundlePath "$RESULT" $ONLY
