#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build dist
swiftc LidLease.swift tests/LeaseTests.swift -o .build/lease-tests
.build/lease-tests
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" main.swift LidSession.swift LidLease.swift -o ".build/Grindset-$arch"
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" LidGuard.swift LidLease.swift -o ".build/GrindsetLidGuard-$arch"
done
bundle="dist/Grindset.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Grindset.app/Contents/Info.plist "$bundle/Contents/Info.plist"
lipo -create .build/Grindset-arm64 .build/Grindset-x86_64 -output "$bundle/Contents/MacOS/Grindset"
lipo -create .build/GrindsetLidGuard-arm64 .build/GrindsetLidGuard-x86_64 -output "$bundle/Contents/MacOS/GrindsetLidGuard"
swift packaging/MakeIcon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$bundle/Contents/MacOS/GrindsetLidGuard"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
