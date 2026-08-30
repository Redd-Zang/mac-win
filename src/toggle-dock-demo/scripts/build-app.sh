#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
project_dir=${package_dir:h:h}
app_dir="$project_dir/outputs/UniversalDockToggle-v1.6.app"

cd "$package_dir"
swift build -c release

if [[ -e "$app_dir" ]]; then
  print -u2 "Refusing to overwrite existing app: $app_dir"
  exit 1
fi

mkdir -p "$app_dir/Contents/MacOS"
cp "$package_dir/.build/release/ToggleDockDemo" "$app_dir/Contents/MacOS/ToggleDockDemo"
cp "$package_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
xattr -cr "$app_dir"
print "Built: $app_dir"

