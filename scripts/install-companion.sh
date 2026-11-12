#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ $# -ne 1 || -z "${TEAM_ID:-}" ]]; then
  print -u2 'Usage: TEAM_ID=<Apple-development-team> ./scripts/install-companion.sh <iPhone-identifier>'
  print -u2 'Find the identifier with: xcrun devicectl list devices'
  exit 2
fi
microscope_device="$1"
microscope_auth=()
if [[ -n "${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
  : "${ASC_KEY_ID:?Set ASC_KEY_ID and ASC_ISSUER_ID together}"
  : "${ASC_ISSUER_ID:?Set ASC_KEY_ID and ASC_ISSUER_ID together}"
  microscope_auth=(-authenticationKeyPath "${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
xcodebuild -project iPhoneMicroscope.xcodeproj -scheme MicroscopeCamera \
  -configuration Debug -destination "id=$microscope_device" \
  -derivedDataPath build/DerivedData-ios -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  "${microscope_auth[@]}" build DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development'
microscope_app='build/DerivedData-ios/Build/Products/Debug-iphoneos/MicroscopeCamera.app'
xcrun devicectl device install app --device "$microscope_device" "$microscope_app"
xcrun devicectl device process launch --device "$microscope_device" com.local.iPhoneMicroscope.Camera
