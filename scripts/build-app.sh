#!/bin/zsh
set -euo pipefail

swift build

bundle_path="build/Minox.app"
binary_path=".build/arm64-apple-macosx/debug/Minox"
resources_path=".build/arm64-apple-macosx/debug/Minox_Minox.bundle"

rm -rf "$bundle_path"
mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_path" "$bundle_path/Contents/MacOS/Minox"
cp "App/Info.plist" "$bundle_path/Contents/Info.plist"
ditto "$resources_path" "$bundle_path/Contents/Resources/Minox_Minox.bundle"

# SMAppService принимает только подписанный бандл — хватает ad-hoc подписи.
codesign --force --sign - --identifier local.minox.app "$bundle_path"

# Автозапуск ссылается на путь бандла, поэтому держим приложение вне build/,
# который пересоздаётся при каждой сборке.
install_path="$HOME/Applications/Minox.app"
mkdir -p "$HOME/Applications"
rm -rf "$install_path"
ditto "$bundle_path" "$install_path"
echo "установлено: $install_path"
