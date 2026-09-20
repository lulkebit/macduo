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
signing_identity="${MACDUO_SIGNING_IDENTITY:-}"
signing_options=()
if [[ -z "$signing_identity" ]]; then
    # Reuse one local certificate so macOS recognizes future builds as the same
    # app. The helper keeps the private key in Keychain, outside the repository.
    signing_details=("${(@f)$(xcrun swift -suppress-warnings scripts/local-signing.swift)}")
    if (( ${#signing_details} != 2 )); then
        echo "Could not resolve the local signing identity." >&2
        exit 1
    fi
    signing_identity="${signing_details[1]}"
    signing_options=(--keychain "${signing_details[2]}" --timestamp=none)
fi
codesign --force --sign "$signing_identity" --identifier de.luke.macduo "${signing_options[@]}" "$app_path"
codesign --verify --strict "$app_path"
echo "Built: $app_path"
if [[ "$signing_identity" == "-" ]]; then
    echo "Signed locally with an ad hoc signature. macOS may request screen recording access again after code changes."
elif [[ -z "${MACDUO_SIGNING_IDENTITY:-}" ]]; then
    echo "Signed with your persistent local development identity."
    echo "Local use only; public distribution still needs Developer ID signing and notarization."
fi
