#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product Outputly
executable="$(swift build -c release --show-bin-path)/Outputly"

lock=.build/.outputly-package.lock
if ! /usr/bin/shlock -f "$lock" -p "$$"; then
    printf '%s\n' 'Another process is packaging Outputly.' >&2
    exit 1
fi

app=.build/Outputly.app
stage=
cleanup() {
    if [ -n "$stage" ]; then
        if [ -e "$stage/previous.app" ] && [ ! -e "$app" ] && ! mv "$stage/previous.app" "$app"; then
            printf 'Previous app is still available at %s\n' "$stage/previous.app" >&2
        else
            rm -rf "$stage"
        fi
    fi
    rm -f "$lock"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

stage=$(mktemp -d .build/outputly-package.XXXXXX)
staged_app="$stage/Outputly.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 755 "$executable" "$staged_app/Contents/MacOS/Outputly"
install -m 644 Packaging/Info.plist "$staged_app/Contents/Info.plist"
# Ship the icon generated from Outputly.svg so packaging needs no rasterizer.
install -m 644 Packaging/Outputly.icns "$staged_app/Contents/Resources/Outputly.icns"

codesign --force --sign - "$staged_app"
codesign --verify --strict "$staged_app"

if [ -e "$app" ]; then
    mv "$app" "$stage/previous.app"
fi
mv "$staged_app" "$app"
printf '%s\n' "$app"
