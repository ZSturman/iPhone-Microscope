#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ $# -ne 1 || ( "$1" != mac && "$1" != ios ) ]]; then
  print -u2 'Usage: ./scripts/release-testflight.sh <mac|ios>'
  print -u2 'Archives and uploads the current source. Increment Info.plist versions first.'
  print -u2 'Uses your Xcode account, or ASC_KEY_ID / ASC_ISSUER_ID / optional ASC_KEY_PATH.'
  exit 2
fi
microscope_platform="$1"
microscope_scheme=iPhoneMicroscope
microscope_destination='generic/platform=macOS'
if [[ "$microscope_platform" == ios ]]; then
  microscope_scheme=MicroscopeCamera
  microscope_destination='generic/platform=iOS'
fi
microscope_auth=()
if [[ -n "${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]]; then
  : "${ASC_KEY_ID:?Set ASC_KEY_ID and ASC_ISSUER_ID together}"
  : "${ASC_ISSUER_ID:?Set ASC_KEY_ID and ASC_ISSUER_ID together}"
  microscope_auth=(-authenticationKeyPath "${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
xcodebuild -project iPhoneMicroscope.xcodeproj -scheme "$microscope_scheme" \
  -configuration Release -destination "$microscope_destination" \
  -derivedDataPath "build/DerivedData-$microscope_platform" \
  -archivePath "build/$microscope_scheme.xcarchive" \
  -allowProvisioningUpdates "${microscope_auth[@]}" archive
xcodebuild -exportArchive -archivePath "build/$microscope_scheme.xcarchive" \
  -exportPath "build/Export-$microscope_platform" \
  -exportOptionsPlist scripts/TestFlightExport.plist \
  -allowProvisioningUpdates "${microscope_auth[@]}"
