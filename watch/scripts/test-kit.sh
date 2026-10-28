#!/bin/sh
# Runs AudayKit's tests on the Mac. With only the Command Line Tools installed, swift-testing
# lives outside the default search path, so point the compiler and linker at it.
set -e
cd "$(dirname "$0")/../AudayKit"
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if xcode-select -p | grep -q CommandLineTools && [ -d "$F/Testing.framework" ]; then
  L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
