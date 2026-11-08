#!/bin/zsh
# Builds a universal "Vimeo Backup.app", signs it with Developer ID (hardened runtime), wraps it in a DMG
# and gets it approved by Apple. Output: build/VimeoBackup-<version>.dmg
#   VERSION=1.0.0 scripts/release.sh            (signed release)
#   SIGN=- scripts/release.sh                   (ad-hoc signed: local packaging check)
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-1.0.0}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD)}
SIGN=${SIGN:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
# App Store Connect API key for Apple's approval step: ASC_KEY (path to .p8), ASC_KEY_ID, ASC_ISSUER.
# Set them in the environment or in scripts/release.env (git-ignored), along with SUPPORT_EMAIL (Send Logs recipient).
# Values already in the environment win; release.env only fills in what is unset.
if [[ -f scripts/release.env ]]; then
  while IFS='=' read -r k v; do
    if [[ $k =~ '^[A-Z_]+$' && -z ${(P)k:-} ]]; then export $k="${(e)v}"; fi
  done < scripts/release.env
fi
[[ -n $SIGN ]] || { echo "No 'Developer ID Application' identity in the keychain."; exit 1; }
KEY=${ASC_KEY:-}; KEY_ID=${ASC_KEY_ID:-}; ISSUER=${ASC_ISSUER:-}
[[ $SIGN == "-" || ( -n $KEY && -n $KEY_ID && -n $ISSUER ) ]] || { echo "Set ASC_KEY, ASC_KEY_ID, ASC_ISSUER (see scripts/release.env)."; exit 1; }

APP="build/Vimeo Backup.app"
DMG="build/VimeoBackup-$VERSION.dmg"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c release --arch arm64 --arch x86_64 --product VBackupApp
cp .build/apple/Products/Release/VBackupApp "$APP/Contents/MacOS/VimeoBackup"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sbl.vimeobackup</string>
  <key>CFBundleName</key><string>Vimeo Backup</string>
  <key>CFBundleDisplayName</key><string>Vimeo Backup</string>
  <key>CFBundleExecutable</key><string>VimeoBackup</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>VBSupportEmail</key><string>${SUPPORT_EMAIL:-}</string>
</dict></plist>
PLIST

if [[ $SIGN == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
fi
codesign --verify --strict --deep "$APP"

# DMG with the app icon as the volume icon: build read-write, flag the custom icon, then compress.
STAGE=build/dmg && mkdir -p $STAGE && cp -R "$APP" $STAGE/ && ln -s /Applications $STAGE/Applications
cp assets/AppIcon.icns $STAGE/.VolumeIcon.icns
hdiutil create -quiet -volname "Vimeo Backup" -srcfolder $STAGE -format UDRW -ov build/rw.dmg
MNT=build/mnt && mkdir -p $MNT
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint $MNT build/rw.dmg
SetFile -a C $MNT
hdiutil detach -quiet $MNT
hdiutil convert -quiet build/rw.dmg -format UDZO -o "$DMG" -ov
rm -rf $STAGE $MNT build/rw.dmg

if [[ $SIGN != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN" "$DMG"
  xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "built $DMG"
