#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ ! -d build/DerivedData-mac/Build/Products/Debug/iPhoneMicroscope.app ]]; then
  ./scripts/build.sh
fi
open build/DerivedData-mac/Build/Products/Debug/iPhoneMicroscope.app --args "$@"
