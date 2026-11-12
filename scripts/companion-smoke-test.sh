#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ $# -ne 1 || ! "$1" =~ '^[0-9]{6}$' ]]; then
  print -u2 'Usage: ./scripts/companion-smoke-test.sh <six-digit-code-from-iPhone>'
  print -u2 'Start sharing on the physical iPhone; close the Mac viewer before running.'
  exit 2
fi
./scripts/build.sh > /tmp/iPhoneMicroscope-build.log 2>&1
microscope_test_dir="$(mktemp -d /tmp/iPhoneMicroscope-companion.XXXXXX)"
print "Temporary test media/report: $microscope_test_dir"
# LaunchServices ensures SwiftUI receives its initial open event and the local-network
# privacy check can resolve the app bundle. A direct executable launch can idle without a window.
open -n -W --stdout /tmp/iPhoneMicroscope-companion-smoke.log --stderr /tmp/iPhoneMicroscope-companion-smoke.log \
  build/DerivedData-mac/Build/Products/Debug/iPhoneMicroscope.app \
  --args --companion-smoke-test "$microscope_test_dir" "$1"
cat "$microscope_test_dir/result.json"
/usr/bin/plutil -extract passed raw "$microscope_test_dir/result.json" | /usr/bin/grep -q true
