#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"
mkdir -p build/AirPodsMotionProbe.app/Contents/MacOS build/AirPodsMotionProbe.app/Contents/Resources build/module-cache Assets dist
app="$PWD/build/AirPodsMotionProbe.app"
if [[ ! -f Assets/AppIcon.icns || Tools/DrawIcon.swift -nt Assets/AppIcon.icns ]]; then
  xcrun swiftc -O -module-cache-path "$PWD/build/module-cache" Tools/DrawIcon.swift -o build/draw-icon
  ./build/draw-icon "$PWD/Assets/AppIcon.iconset"
  iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
fi
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/build/module-cache" \
  Sources/ProbeState.swift Sources/MotionPipeline.swift Sources/HeadPointerEngine.swift Sources/FruitGame.swift \
  Sources/FruitGameView.swift Sources/FruitScene.swift Sources/EarGameController.swift Sources/main.swift \
  -framework AppKit -framework CoreMotion -framework QuartzCore -framework SpriteKit \
  -o "$app/Contents/MacOS/AirPodsMotionProbe"
cp Info.plist "$app/Contents/Info.plist"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
"$app/Contents/MacOS/AirPodsMotionProbe" --self-test
plutil -lint "$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
ditto "$app" "$PWD/dist/FruitSlice.app"
ditto -c -k --sequesterRsrc --keepParent "$PWD/dist/FruitSlice.app" "$PWD/dist/FruitSlice-macOS-$(uname -m).zip"
printf 'Built: %s\n' "$app"
printf 'Release: %s\n' "$PWD/dist/FruitSlice-macOS-$(uname -m).zip"
