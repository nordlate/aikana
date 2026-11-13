# Ajoissa

A macOS menu bar app that answers one question: did everything that should have run actually run, on all my machines?

Ajoissa watches scheduled jobs (launchd on Macs, systemd timers and cron on Linux over SSH). You declare in a config file what is expected to run, where, when, and what counts as success. Ajoissa reports jobs that failed, jobs that never ran, and jobs that exited cleanly but did not produce their result.

"Ajoissa" is Finnish for "on time".

## Status

Scaffold only. The app shows an empty menu bar panel and the command line tool only reports its version. The plan is in the issues, in three milestones: one Mac, other machines, release.

## Layout

```
Ajoissa/                  Menu bar app (SwiftUI, MenuBarExtra)
AjoissaTests/             App tests
Packages/AjoissaCore/     The engine, a Swift package
  Sources/AjoissaCore/    Config, collectors, schedule logic, checks
  Sources/AjoissaCLI/     The `ajoissa` command line tool
  Tests/AjoissaCoreTests/ Engine tests
```

## Principles

- **Read-only.** Ajoissa never starts, stops or edits a job.
- **Nothing personal in the repo.** No real host names, paths or job names. Each user's setup is a config file kept elsewhere.
- **The engine stands alone.** `AjoissaCore` uses Foundation only and does not depend on the app, so it can be published as its own package.
- **Not sandboxed.** The app needs `launchctl`, `ssh` and the user's SSH config. It is distributed directly, not through the Mac App Store.

## Build and test

Requires Xcode 27 and macOS 15.3 or later.

```sh
xcodebuild -scheme Ajoissa -destination 'platform=macOS' build
xcodebuild test -scheme Ajoissa -destination 'platform=macOS,arch=arm64'
```

The engine and the command line tool also build without Xcode's project:

```sh
cd Packages/AjoissaCore
swift test
swift run ajoissa --version
```
