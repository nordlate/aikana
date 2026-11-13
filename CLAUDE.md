# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

`xcode-select` may point at the Command Line Tools; prefix `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if it fails to find Xcode.

```bash
# Build
xcodebuild -scheme Ajoissa -destination 'platform=macOS' build

# Run all tests (app tests and AjoissaCore tests)
xcodebuild test -scheme Ajoissa -destination 'platform=macOS,arch=arm64'

# Run a single test class
xcodebuild test -scheme Ajoissa -destination 'platform=macOS,arch=arm64' -only-testing:AjoissaCoreTests/AjoissaCoreTests

# Engine only, without the Xcode project (fastest loop for AjoissaCore work)
cd Packages/AjoissaCore && swift test
cd Packages/AjoissaCore && swift run ajoissa --version
cd Packages/AjoissaCore && swift run ajoissa validate --config Examples/config.example.json5

# Lint
swiftlint lint

# Lint with auto-fix
swiftlint lint --fix

# Dead code analysis
periphery scan
```

## Architecture

macOS menu bar app (deployment target: macOS 15.3, Swift 6 language mode) on top of a local Swift package.

```
Ajoissa/                  The app: MenuBarExtra, SwiftUI views, notifications. No Dock icon (LSUIElement).
  App/                    Entry point
  Features/               SwiftUI views and their view models, by feature
AjoissaTests/             XCTest, hosted in the app
Packages/AjoissaCore/     The engine
  Sources/AjoissaCore/    Config model, collectors (launchd, systemd, cron), run evaluation, checks
  Sources/AjoissaCLI/     `ajoissa` command line tool (product name `ajoissa`)
  Tests/AjoissaCoreTests/ XCTest
```

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`: new files under `Ajoissa/` and `AjoissaTests/` are included without editing the project file. The package picks up files under its `Sources/` and `Tests/` folders on its own.

## Rules

- **AjoissaCore is Foundation only.** No AppKit, SwiftUI or UserNotifications in it, and it never imports the app. It will be published as a separate package; keep its public API deliberate and documented.
- **Logic goes in AjoissaCore, presentation in the app.** If it can be tested without a window, it belongs in the package.
- **Read-only.** Ajoissa observes jobs. Do not add code that starts, stops, loads, unloads or edits a job, a plist, a unit or a crontab.
- **Nothing personal in the repo.** No real host names, user names, paths or job names in sources, tests, fixtures or examples. Use made-up ones.
- **Remote commands** (once SSH support exists) must be read-only, built without string concatenation into a shell, and listed in one place in the code and in the README.
- **Time is injected.** Schedule and evaluation logic takes the current time and its evidence as parameters; no `Date()` and no I/O inside it.
- **Not sandboxed, hardened runtime on.** Do not enable the App Sandbox.
- **The config is validated in one place.** `ConfigLoader` is the only way to get a `Config`, and it reports every problem with a path and a message written for a person. A new setting needs: the model, the parser, a test per rule with the exact message, and an entry in `Packages/AjoissaCore/Examples/config.example.json5`. Unknown settings are errors.
- **Values that reach another program must stay one harmless word.** Host aliases, launchd labels and unit names may only contain letters, digits and a few listed punctuation characters, and may not start with `-`: they end up as arguments to `launchctl` and `ssh`, and ssh hands its command to a remote shell. Free text (paths, patterns, cron text) must be a single line. Do not loosen these without a test that shows the value is quoted safely where it is used.
- **Tests are XCTest.** The command line target is named `AjoissaCLI` so its module does not collide with the app module `Ajoissa` on a case-insensitive disk.

## Tasks

Tasks are GitHub issues in `nordlate/ajoissa`. Versions change only in a separate bump PR; feature and fix PRs do not touch them.
