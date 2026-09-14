#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
app_path="$PWD/dist/MacDuo.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/MacDuo "$app_path/Contents/MacOS/MacDuo"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
fi
signing_identity="${MACDUO_SIGNING_IDENTITY:--}"
codesign --force --sign "$signing_identity" --identifier de.luke.macduo "$app_path"
codesign --verify --strict "$app_path"
echo "Built: $app_path"
if [[ "$signing_identity" == "-" ]]; then
    echo "Signed locally with an ad hoc signature. macOS may request screen recording access again after code changes."
fi
