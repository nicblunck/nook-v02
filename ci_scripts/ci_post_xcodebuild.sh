#!/bin/zsh
# Xcode Cloud runs this after every xcodebuild action. When the action produced
# an App Store–signed build, write TestFlight's "What to Test" from the commits
# since the last release tag, so testers see what changed without anyone
# typing it up. Xcode Cloud picks the file up from TestFlight/ beside the project.
set -e

if [[ -z "$CI_APP_STORE_SIGNED_APP_PATH" ]]; then
    exit 0
fi

cd "$CI_PRIMARY_REPOSITORY_PATH"
git fetch --quiet --tags --unshallow 2>/dev/null || git fetch --quiet --tags

last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
range=${last_tag:+$last_tag..}HEAD

mkdir -p TestFlight
git log "$range" --no-merges --max-count=20 --pretty=format:'• %s' \
    >! TestFlight/WhatToTest.en-US.txt
