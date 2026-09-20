#!/bin/bash
#
# Show every Nook share extension macOS currently knows about, and unregister
# the ones that are not the app you actually run.
#
#   Scripts/share-extensions.sh              list them, change nothing
#   Scripts/share-extensions.sh --prune      unregister everything but the keeper
#   Scripts/share-extensions.sh --keep PATH  name the keeper yourself
#
# Why this exists: the share sheet does not list one row per app, it lists one
# row per registered copy of an extension. macOS registers a copy for every
# Nook.app it has ever seen on disk, and a development Mac collects those
# quickly — one per DerivedData folder, which means one per checkout and one
# per project regeneration that moved the folder, plus one per archive, plus
# whatever got dragged into /Applications along the way. They all carry the
# same extension, so the sheet fills up with identical Nook entries and none of
# them go away by rebuilding. Nothing in project.yml can prevent this; the
# copies are on the disk, not in the project.
#
# This script never deletes anything. Unregistering is enough to clear the
# sheet, and for a build product that is about to be overwritten anyway it is
# the right depth. Where a stale copy will keep coming back, the script says so
# and prints the bundle, so removing it stays a decision made by a person.

set -uo pipefail

cd "$(dirname "$0")/.."

# Every share extension this project and its predecessor have ever shipped. The
# old repository's extension is a different bundle id with its own row in the
# sheet, so a Mac that built both shows two lineages of duplicates, not one.
readonly EXTENSION_IDS=(
    com.nicolasblunck.nook.app.macshare   # this repository, macOS
    com.nicolasblunck.nook.app.share      # this repository, iOS
    com.nicolasblunck.nook.share          # the previous repository, macOS
)

bold=$'\033[1m'; dim=$'\033[2m'; warn=$'\033[33m'; ok=$'\033[32m'; off=$'\033[0m'

keep=""
prune=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prune) prune=1; shift ;;
        --keep)  keep="${2:-}"; [ -n "$keep" ] || { echo "--keep needs a path" >&2; exit 1; }; shift 2 ;;
        -h|--help)
            printf 'Show every Nook share extension macOS knows about, and unregister the\n'
            printf 'ones that are not the app you actually run.\n\n'
            printf '  Scripts/share-extensions.sh              list them, change nothing\n'
            printf '  Scripts/share-extensions.sh --prune      unregister everything but the keeper\n'
            printf '  Scripts/share-extensions.sh --keep PATH  name the keeper yourself\n\n'
            printf 'Nothing is ever deleted. Bundles that can register themselves again are\n'
            printf 'listed so removing one stays a decision you make.\n'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

if ! command -v pluginkit >/dev/null 2>&1; then
    echo "error: pluginkit is missing — this script only works on macOS" >&2
    exit 1
fi

# ------------------------------------------------------------------ the keeper
#
# "The active Nook" is whichever copy the user actually launches. On a machine
# that runs Nook out of Xcode that is this checkout's Debug build, so ask the
# build where it puts things rather than guessing at the newest DerivedData
# folder — several will match the name and the newest is not reliably the one
# being run.

built=""
if command -v xcodebuild >/dev/null 2>&1; then
    built="$(
        xcodebuild -project Nook.xcodeproj -scheme Nook-macOS \
            -destination 'platform=macOS' -configuration Debug \
            -showBuildSettings 2>/dev/null |
        awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{ print $2 "/Nook.app"; exit }'
    )"
fi

# This checkout's own build wins the guess. Preferring /Applications would read
# as the safer default and is the opposite: the copy sitting there is as likely
# to be the previous repository's Nook, and keeping that one would unregister
# the extension belonging to the app actually being worked on.
if [ -z "$keep" ]; then
    if [ -n "$built" ]; then
        keep="$built"
    elif [ -d "/Applications/Nook.app" ]; then
        keep="/Applications/Nook.app"
    fi
fi

if [ -z "$keep" ]; then
    echo "error: could not work out which Nook.app to keep." >&2
    echo "Name it yourself: Scripts/share-extensions.sh --keep /path/to/Nook.app" >&2
    exit 1
fi

# Compare resolved paths. A keeper reached through a symlink and the same
# bundle reached directly would otherwise look like two different apps, and the
# script would helpfully unregister the one being kept.
resolve() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || printf '%s' "$1"; }
keep_resolved="$(resolve "$keep")"

printf '%sKeeping%s  %s\n' "$bold" "$off" "$keep"
[ -d "$keep" ] || printf '  %sthat bundle is not on disk right now%s\n' "$warn" "$off"

# Two plausible keepers is exactly when a wrong guess costs something, so say it
# rather than picking quietly.
if [ "$keep" = "$built" ] && [ -d "/Applications/Nook.app" ]; then
    printf '  %sthere is also a Nook.app in /Applications — if that is the one you run,\n' "$warn"
    printf '  rerun with --keep /Applications/Nook.app%s\n' "$off"
fi
printf '  %soverride with --keep /path/to/Nook.app%s\n' "$dim" "$off"
printf '\n'

# ------------------------------------------------------------------- the list
#
# pluginkit prints a block per registered extension; -A includes the ones the
# user has already switched off, which still occupy a row in the sheet. The
# leading character of the header line is the enabled state, and the Path line
# is the only thing that distinguishes one copy from another.

registrations="$(
    for id in "${EXTENSION_IDS[@]}"; do
        pluginkit -mAvvv -i "$id" 2>/dev/null
    done
)"

paths="$(printf '%s\n' "$registrations" | awk '/^\t*Path[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print }')"
[ -n "$paths" ] || paths="$(printf '%s\n' "$registrations" | awk '/\.appex$/ && /\// { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }')"
paths="$(printf '%s\n' "$paths" | grep -v '^$' | sort -u)"

if [ -z "$paths" ]; then
    printf '%sNo Nook share extensions are registered.%s\n' "$ok" "$off"
    printf '%sIf the sheet still shows some, they are registered under a bundle id this\n' "$dim"
    printf 'script does not know about — send it the output of:\n'
    printf '  pluginkit -mAvvv -p com.apple.share-services | grep -i nook%s\n' "$off"
    exit 0
fi

# Say where a copy came from. Which bucket a stray falls into is the whole
# answer to "will this come back", so it is worth naming rather than printing a
# bare path and leaving the reader to recognise a DerivedData hash.
origin_of() {
    case "$1" in
        *"/Library/Developer/Xcode/DerivedData/"*) printf 'a build folder' ;;
        *"/Library/Developer/Xcode/Archives/"*)    printf 'an archive' ;;
        /Applications/*)                            printf '/Applications' ;;
        "$HOME"/Applications/*)                     printf '~/Applications' ;;
        *"/Xcode/UserData/Previews/"*|*"/Intermediates.noindex/"*) printf 'a preview build' ;;
        *) printf 'a loose copy' ;;
    esac
}

# The app bundle an extension sits inside: Nook.app/Contents/PlugIns/X.appex.
# Unregistering an appex whose app is still on disk only lasts until macOS
# rescans, so the app bundle is what has to go for a stray to stay gone.
app_of() {
    case "$1" in
        */Contents/PlugIns/*) printf '%s' "${1%%/Contents/PlugIns/*}" ;;
        *) printf '' ;;
    esac
}

strays=()
kept=0

printf '%sRegistered%s\n' "$bold" "$off"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    app="$(app_of "$path")"
    if [ -n "$app" ] && [ "$(resolve "$app")" = "$keep_resolved" ]; then
        printf '  %skeep%s  %s  %s(%s)%s\n' "$ok" "$off" "$path" "$dim" "$(origin_of "$path")" "$off"
        kept=$((kept + 1))
    else
        printf '  %sstray%s %s  %s(%s)%s\n' "$warn" "$off" "$path" "$dim" "$(origin_of "$path")" "$off"
        strays+=("$path")
    fi
done <<< "$paths"

printf '\n'
if [ "${#strays[@]}" -eq 0 ]; then
    printf '%sOne Nook in the share sheet. Nothing to do.%s\n' "$ok" "$off"
    exit 0
fi

printf '%s%s stray registration(s)%s — that is %s extra Nook row(s) in the share sheet.\n' \
    "$bold" "${#strays[@]}" "$off" "${#strays[@]}"

if [ "$prune" -eq 0 ]; then
    printf '\nRun it again with %s--prune%s to unregister them.\n' "$bold" "$off"
    exit 0
fi

# ------------------------------------------------------------------- pruning

printf '\n%sUnregistering%s\n' "$bold" "$off"
failed=0
for path in "${strays[@]}"; do
    if pluginkit -r "$path" >/dev/null 2>&1; then
        printf '  %sdone%s  %s\n' "$ok" "$off" "$path"
    else
        printf '  %sfailed%s %s\n' "$warn" "$off" "$path"
        failed=$((failed + 1))
    fi
done

# A registration whose bundle is gone stays gone. One whose bundle is still
# there is only asleep, so list those separately with the command that would
# settle it — and leave running that command to the reader, because it deletes
# a build someone may still want.
lingering=()
for path in "${strays[@]}"; do
    app="$(app_of "$path")"
    [ -n "$app" ] && [ -d "$app" ] && lingering+=("$app")
done

if [ "${#lingering[@]}" -gt 0 ]; then
    printf '\n%sStill on disk%s\n' "$bold" "$off"
    printf '%sThese bundles can register themselves again the next time macOS scans.\n' "$dim"
    printf 'Delete the ones you do not want, once you are sure which app you run:%s\n' "$off"
    printf '%s\n' "${lingering[@]}" | sort -u | sed 's/^/  rm -rf /'
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf '%sDone. Reopen the share sheet to see the shorter list.%s\n' "$ok" "$off"
else
    printf '%s%s could not be unregistered.%s Their bundles are listed above; removing one\n' \
        "$warn" "$failed" "$off"
    printf 'clears its row for good.\n'
fi
