#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh > /tmp/iPhoneMicroscope-build.log 2>&1
microscope_test_dir="$(mktemp -d /tmp/iPhoneMicroscope-smoke.XXXXXX)"
build/DerivedData-mac/Build/Products/Debug/iPhoneMicroscope.app/Contents/MacOS/iPhoneMicroscope --smoke-test "$microscope_test_dir" > /tmp/iPhoneMicroscope-smoke.log 2>&1
cat "$microscope_test_dir/result.json"
/usr/bin/plutil -extract passed raw "$microscope_test_dir/result.json" | /usr/bin/grep -q true
