#!/bin/bash
# Build without a device identity, then ad-hoc sign the staged IPA so sideloading
# tools can discover and replace its App Group entitlement. Device re-signing is required.
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/TaiKueriRunner.app"
IPA_PATH="$BUILD_DIR/TaiKueriRunner-unsigned.ipa"
LOG_PATH="$BUILD_DIR/unsigned-build.log"

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

if ! /usr/bin/xcrun --find xcodebuild >/dev/null 2>&1 || ! /usr/bin/xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "Error: iOS SDKを含むXcodeをインストールし、xcode-selectで選択してください。" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
echo "実機向けReleaseを署名なしでビルドします。"
echo "ビルドログ: $LOG_PATH"

# Resolve relative project settings independently of the caller's directory.
cd "$ROOT_DIR"
if ! /usr/bin/xcrun xcodebuild \
    -project "$ROOT_DIR/TaiKueriRunner.xcodeproj" \
    -scheme TaiKueriRunner \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    'CODE_SIGN_IDENTITY=' \
    build 2>&1 | tee "$LOG_PATH"; then
    echo "Error: ビルドに失敗しました。$LOG_PATH を確認してください。" >&2
    exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: ビルド済みアプリが見つかりません: $APP_PATH" >&2
    exit 1
fi

# Only this invocation's temporary directory is removed on exit.
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.unsigned-package.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/Payload"
/usr/bin/ditto --norsrc --noextattr "$APP_PATH" "$STAGING_DIR/Payload/TaiKueriRunner.app"
# Signing only the staged copy leaves the Xcode build product untouched.
STAGED_APP="$STAGING_DIR/Payload/TaiKueriRunner.app"
ENTITLEMENTS="$STAGING_DIR/entitlements.plist"
cp "$ROOT_DIR/TaiKueriRunner/TaiKueriRunner.entitlements" "$ENTITLEMENTS"
APP_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$ENTITLEMENTS")
if [[ ! "$APP_GROUP" =~ ^group\.[A-Za-z0-9._-]+$ ]]; then
    echo "Error: 再署名用のApp Group IDが無効です: $APP_GROUP" >&2
    exit 1
fi
/usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
/usr/bin/codesign --display --entitlements "$STAGING_DIR/signed-entitlements.plist" --xml "$STAGED_APP"
SIGNED_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$STAGING_DIR/signed-entitlements.plist")
if [[ "$SIGNED_GROUP" != "$APP_GROUP" ]]; then
    echo "Error: IPAのApp Group宣言を検証できませんでした。" >&2
    exit 1
fi
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGING_DIR/Payload" "$STAGING_DIR/TaiKueriRunner-unsigned.ipa"
mv -f "$STAGING_DIR/TaiKueriRunner-unsigned.ipa" "$IPA_PATH"

echo
echo "完了: $IPA_PATH"
echo "App:  $APP_PATH"
echo "App Group宣言を保持するad-hoc署名済みIPAです。そのまま端末にはインストールできません。"
echo "シンプルモード: AltStore・SideStore・SideloadlyでApple IDを使ってインストールしてください（無料・有料共通、IDの手動設定不要）。"
