#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: XcodeGen is required to verify Nook.xcodeproj" >&2
    exit 1
fi

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/nook-project-check.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

source_copy="$temporary_root/source"
mkdir -p "$source_copy"
rsync -a \
    --exclude='.build/' \
    --exclude='.swiftpm/' \
    "$repository_root/project.yml" \
    "$repository_root/Nook" \
    "$repository_root/NookMacShare" \
    "$repository_root/Packages" \
    "$source_copy/"

(cd "$source_copy" && xcodegen generate --spec project.yml --quiet)

status=0
compare_file() {
    relative_path=$1
    if ! diff -u "$repository_root/$relative_path" "$source_copy/$relative_path"; then
        status=1
    fi
}

compare_file Nook.xcodeproj/project.pbxproj
compare_file Nook/Sources/iOS-Info.plist
compare_file Nook/macOS-Info.plist
compare_file Nook/Sources/Nook.entitlements
compare_file Nook-macOS.entitlements
compare_file Nook/ShareExtension/Info.plist
compare_file Nook/ShareExtension/ShareExtension.entitlements
compare_file NookMacShare/Info.plist
compare_file NookMacShare/NookMacShare.entitlements

if ! diff -ru \
    "$repository_root/Nook.xcodeproj/xcshareddata/xcschemes" \
    "$source_copy/Nook.xcodeproj/xcshareddata/xcschemes"; then
    status=1
fi

if [ "$status" -ne 0 ]; then
    echo "error: generated Xcode files are outdated; run 'xcodegen generate --spec project.yml'" >&2
    exit "$status"
fi

echo "Generated Xcode files match project.yml."
