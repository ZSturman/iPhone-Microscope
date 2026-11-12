#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if /usr/bin/pgrep -x iPhoneMicroscope > /dev/null; then
  print -u2 'Close iPhone Microscope before running the hardware check.'
  exit 1
fi
./scripts/build.sh > /tmp/iPhoneMicroscope-build.log 2>&1
microscope_test_dir="$(mktemp -d /tmp/iPhoneMicroscope-iphone.XXXXXX)"
print "Testing the connected iPhone; media and report: $microscope_test_dir"
build/DerivedData-mac/Build/Products/Debug/iPhoneMicroscope.app/Contents/MacOS/iPhoneMicroscope --iphone-smoke-test "$microscope_test_dir" > /tmp/iPhoneMicroscope-iphone-check.log 2>&1
cat "$microscope_test_dir/result.json"
/usr/bin/plutil -extract passed raw "$microscope_test_dir/result.json" | /usr/bin/grep -q true
