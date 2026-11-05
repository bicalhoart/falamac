#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
bin_dir="$(swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --show-bin-path)"
app_dir="dist/FalaMac.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/FalaMac" "$app_dir/Contents/MacOS/FalaMac"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --sign - --identifier art.bicalho.falamac "$app_dir"
codesign --verify --strict "$app_dir"
du -sh "$app_dir"
printf 'Aplicativo pronto em %s/%s\n' "$PWD" "$app_dir"
