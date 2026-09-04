# Nook

A SwiftUI app targeting iOS and macOS.

## Getting started

The Xcode project is generated from [`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not committed to git.

```bash
brew install xcodegen  # if not already installed
xcodegen generate
open Nook.xcodeproj
```

## Project structure

- `Nook/Sources` — shared SwiftUI source, used by both the iOS and macOS targets
- `Nook/Resources` — asset catalog (`Assets.xcassets`)
- `project.yml` — XcodeGen project spec
