#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
developer_frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ ! -d "$developer_frameworks/Testing.framework" ]]; then
  developer_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
swift test --disable-xctest --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security \
  -Xswiftc -F -Xswiftc "$developer_frameworks" -Xlinker -rpath -Xlinker "$developer_frameworks" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
