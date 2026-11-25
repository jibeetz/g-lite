#!/bin/sh
# Builds mac/build/G-Lite.app (universal, ad-hoc signed) after its self-test passes, then quits the running app and copies the new one
# to /Applications (or ~/Applications when /Applications isn't writable), like app\build.cmd. It doesn't start it. The version comes
# from app/Program.cs.
set -e
cd "$(dirname "$0")"
version=$(sed -n 's/.*AssemblyInformationalVersion("\(.*\)").*/\1/p' ../app/Program.cs)
short=$(sed -n 's/.*AssemblyVersion("\(.*\)").*/\1/p' ../app/Program.cs)
out=build
app=$out/G-Lite.app
rm -rf "$app" "$out/GLite.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

for arch in arm64 x86_64; do
  echo "compile $arch"
  # ScreenCaptureKit is weakly linked: it came with macOS 12.3, and the app starts on 12.0 without it.
  swiftc -O -swift-version 5 -target $arch-apple-macos12 -Xlinker -weak_framework -Xlinker ScreenCaptureKit -o $out/GLite-$arch Sources/*.swift
done
lipo -create -output "$app/Contents/MacOS/GLite" $out/GLite-arm64 $out/GLite-x86_64
rm $out/GLite-arm64 $out/GLite-x86_64

# The key layouts, the same files the Windows build embeds (app/models/*.json).
mkdir -p "$app/Contents/Resources/models"
cp ../app/models/*.json "$app/Contents/Resources/models/"

echo "selftest"
"$app/Contents/MacOS/GLite" --selftest

echo "icon"
rm -rf $out/GLite.iconset
"$app/Contents/MacOS/GLite" --iconset $out/GLite.iconset
iconutil -c icns -o "$app/Contents/Resources/GLite.icns" $out/GLite.iconset
rm -rf $out/GLite.iconset

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>org.g-lite.GLite</string>
  <key>CFBundleName</key><string>G-Lite</string>
  <key>CFBundleDisplayName</key><string>G-Lite</string>
  <key>CFBundleExecutable</key><string>GLite</string>
  <key>CFBundleIconFile</key><string>GLite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$short</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>NSMicrophoneUsageDescription</key><string>Test sidetone opens the headset's microphone, so you hear yourself as in a call. G-Lite doesn't keep or send the sound.</string>
</dict>
</plist>
EOF

# A real identity when there is one (GLITE_SIGN, else the first Apple Development certificate): macOS ties Input Monitoring to the
# signature, and an ad-hoc one changes at every build, so each build lost the permission.
identity=${GLITE_SIGN:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}
echo "sign with ${identity:-an ad-hoc signature}"
codesign --force --sign "${identity:--}" "$app"

target=/Applications
[ -w $target ] || { target="$HOME/Applications"; mkdir -p "$target"; }
echo "install to $target"
# Quit, not kill, so G-Lite gives the keys back to the saved lighting.
osascript -e 'tell application id "org.g-lite.GLite" to quit' >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x GLite >/dev/null || break; perl -e 'select(undef,undef,undef,0.3)'; done
rm -rf "$target/G-Lite.app"
ditto "$app" "$target/G-Lite.app"
echo "built $target/G-Lite.app ($version)"
