# Releasing Nook

Nook ships as one universal purchase — iPhone, iPad and Mac under the bundle ID
`com.nicolasblunck.nook.app` — through TestFlight first and the App Store
later. Xcode Cloud builds, signs and uploads; nothing is archived by hand.

## Versions

- **Version** (`MARKETING_VERSION`, set once in the project for all four
  targets): `0.x` while Nook is TestFlight-only; `1.0` is the first App Store
  release. Bump the minor for each batch of work sent to external testers.
- **Build** (`CURRENT_PROJECT_VERSION`): never edited. Xcode Cloud assigns its
  own increasing build number to every build it archives.
- All `Info.plist` files read both from build settings, so the app and its
  share extensions can't drift apart — App Store Connect rejects a mismatch.
- **Tag** `v<version>-<build>` (e.g. `v0.1-12`) on the commit behind each build
  that goes to external testers or the App Store. The TestFlight notes script
  uses the last tag as its starting point.

## Channels

| Channel | Who | Gate |
| --- | --- | --- |
| Internal TestFlight | Nic's own devices (up to 100 App Store Connect users) | none — available minutes after upload |
| External TestFlight | invited testers / public link | Beta App Review for the first build of each version |
| App Store | everyone | App Review |

## Xcode Cloud workflows

Workflows live in App Store Connect (Xcode Cloud ▸ product "Nook-iOS", a
name Xcode picked; it covers both platforms). Two of them:

1. **Release** (exists) — start condition: manual only, on `main`. Actions:
   *Archive* `Nook-iOS` and *Archive* `Nook-macOS`, **both** with
   Distribution Preparation *App Store Connect*. With *None* an archive builds
   but never uploads; *TestFlight (Internal Testing Only)* builds can never go
   to external testers or review.
2. **Test** (not yet) — start condition: every change to `main` and every pull
   request. Action: *Test* on `Nook-macOS`. No distribution.

Tests are kept out of Release on purpose: Xcode Cloud skips post-actions when
any action fails, so a flaky test would stop a build reaching TestFlight.

`ci_scripts/ci_post_xcodebuild.sh` writes TestFlight's "What to Test" from the
commit subjects since the last `v*` tag.

## Cutting a TestFlight build

1. Merge to `main` and push.
2. If the SwiftData model changed since the last release, deploy the CloudKit
   schema (below) **before** starting the build.
3. App Store Connect ▸ Xcode Cloud ▸ Nook-iOS ▸ Builds ▸ **Start Build** ▸
   Release ▸ `main`. Not *Rebuild*: that reruns the old commit.
4. Builds reach TestFlight processed within ~15 minutes. Add each platform's
   new build to the **Alpha Testing** internal group (TestFlight ▸ Alpha
   Testing ▸ Builds ▸ +). iPhone/iPad install from TestFlight on iOS, the Mac
   build from the TestFlight app on the Mac.
5. For external testers: add the build to an external group, and tag the
   commit `v<version>-<build>` and push the tag.

## CloudKit schema

Sync runs against the container `iCloud.com.nicolasblunck.nook.app`. Debug
builds from Xcode talk to its **Development** environment; every TestFlight
and App Store build talks to **Production**, which starts empty. Record types
exist in Production only after they are deployed:

CloudKit Console ▸ `iCloud.com.nicolasblunck.nook.app` ▸ Schema ▸ *Deploy
Schema Changes…*

Production schema is additive-only: fields and types can be added but never
removed or retyped. Run the Debug app against Development first so every
record type and field has been created there, then deploy.

## Before submission

Already in the project:

- `PrivacyInfo.xcprivacy` in the app and both share extensions (UserDefaults,
  file timestamps of imported files, system uptime; no tracking, no data
  collected).
- `ITSAppUsesNonExemptEncryption = NO` — Nook only hashes with CryptoKit and
  relies on the OS for HTTPS and file protection, which is exempt. This skips
  the export-compliance question on every upload.
- `LSApplicationCategoryType = public.app-category.productivity` on the Mac
  (required by the Mac App Store).
- The Mac app is sandboxed (required by the Mac App Store): read-write for
  user-picked files, outgoing network, the shared app group.
- Push entitlements say `development`; distribution signing rewrites them to
  `production` on export.

Still to do in App Store Connect before the first external build or review:
App Privacy answers ("Data Not Collected"), privacy policy URL, beta
description and feedback email, and later the App Store listing and
screenshots.

## One-time setup (done 25 Sep 2026)

- [x] App Store Connect app "Nook - Stash Anything", platforms iOS and macOS,
      bundle ID `com.nicolasblunck.nook.app`. The home-screen name stays "Nook".
- [x] CloudKit schema deployed to Production.
- [x] Xcode Cloud connected to GitHub; Release workflow.
- [x] TestFlight internal group "Alpha Testing" with Nic.
- [ ] Test workflow.
