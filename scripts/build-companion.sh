#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Compile the actual iPhone architecture; no signing/account needed for this check.
xcodebuild -project iPhoneMicroscope.xcodeproj -scheme MicroscopeCamera \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData-ios build CODE_SIGNING_ALLOWED=NO
