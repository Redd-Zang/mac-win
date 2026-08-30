#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
project_dir=${package_dir:h:h}
app_dir="$project_dir/outputs/MacWin.app"

cd "$package_dir"
swift build -c release

if [[ -e "$app_dir" ]]; then
  print -u2 "Refusing to overwrite existing app: $app_dir"
  exit 1
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/.build/release/ToggleDockDemo" "$app_dir/Contents/MacOS/MacWin"
cp "$package_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns "$app_dir/Contents/Resources/MacWin.icns"
xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
xattr -cr "$app_dir"
install_dir="/Applications/MacWin.app"
if [[ -e "$install_dir" ]]; then
  rm -rf "$install_dir"
fi
ditto "$app_dir" "$install_dir"
xattr -cr "$install_dir"
codesign --force --deep --sign - "$install_dir"
print "Built and installed: $install_dir"
open "$install_dir"

