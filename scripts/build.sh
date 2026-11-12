#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
microscope_signing=()
if [[ "${AD_HOC:-0}" == '1' ]]; then
  microscope_signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
elif [[ -n "${TEAM_ID:-}" ]]; then
  microscope_signing=("DEVELOPMENT_TEAM=$TEAM_ID")
fi
xcodebuild -project iPhoneMicroscope.xcodeproj -scheme iPhoneMicroscope -configuration Debug -derivedDataPath build/DerivedData-mac build CODE_SIGNING_ALLOWED=YES "${microscope_signing[@]}"
