#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if pgrep -x iPhoneMicroscope >/dev/null; then
  print -u2 'Quit iPhone Microscope first so any recording can finish, then rerun this command.'
  exit 1
fi
./scripts/build.sh
microscope_destination='/Applications/iPhone Microscope.app'
if [[ -e "$microscope_destination" ]]; then
  mkdir -p "$HOME/.Trash"
  mv "$microscope_destination" "$HOME/.Trash/iPhone Microscope-replaced-$(date +%Y%m%d-%H%M%S).app"
fi
ditto build/DerivedData-mac/Build/Products/Debug/iPhoneMicroscope.app "$microscope_destination"
open -F "$microscope_destination"
