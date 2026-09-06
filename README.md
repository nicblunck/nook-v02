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
- `Nook/Resources` — asset catalog (`Assets.xcassets`) and the app icon (`AppIcon.icon`)
- `project.yml` — XcodeGen project spec

## App icon

`Nook/Resources/AppIcon.icon` is an [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
bundle — layered SVGs plus `icon.json`, edited by opening it in Icon Composer.
Xcode compiles it into the Liquid Glass icon and generates the flat fallbacks
older OS versions need, so there is no `AppIcon.appiconset`.
