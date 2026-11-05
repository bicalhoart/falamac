#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build_args=(-c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
  -Xswiftc -gnone
  -Xswiftc -debug-prefix-map -Xswiftc "$PWD=/FalaMac"
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=/FalaMac")
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/FalaMac-build.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
app_dir="$stage_dir/FalaMac.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
COPYFILE_DISABLE=1 cp "$bin_dir/FalaMac" "$app_dir/Contents/MacOS/FalaMac"
# Remove debug symbols and linker object paths before signing the shared build.
strip -S "$app_dir/Contents/MacOS/FalaMac"
COPYFILE_DISABLE=1 cp Resources/Info.plist "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --sign - --identifier art.bicalho.falamac "$app_dir"
codesign --verify --strict "$app_dir"
mkdir -p dist
ditto --norsrc "$app_dir" dist/FalaMac.app
# Archive the verified staging bundle, before cloud-synced folders add metadata.
ditto -c -k --norsrc --keepParent "$app_dir" dist/FalaMac.zip
python3 scripts/check-release.py dist/FalaMac.zip
mkdir "$stage_dir/verify"
unzip -q dist/FalaMac.zip -d "$stage_dir/verify"
codesign --verify --strict "$stage_dir/verify/FalaMac.app"
du -sh dist/FalaMac.app dist/FalaMac.zip
printf 'App ready at %s/dist/FalaMac.app\n' "$PWD"
