# Ajoissa

A macOS menu bar app that answers one question: did everything that should have run actually run, on all my machines?

Ajoissa watches scheduled jobs (launchd on Macs, systemd timers and cron on Linux over SSH). You declare in a config file what is expected to run, where, when, and what counts as success. Ajoissa reports jobs that failed, jobs that never ran, and jobs that exited cleanly but did not produce their result.

"Ajoissa" is Finnish for "on time".

## Status

Early. The config file format and its validation exist, with `ajoissa validate` to check a file. Nothing reads jobs yet: the app shows an empty menu bar panel. The plan is in the issues, in three milestones: one Mac, other machines, release.

## Config

Ajoissa reads `~/.config/ajoissa/config.json5`. Another file can be named with `--config <path>` or the `AJOISSA_CONFIG` environment variable. The format is JSON5, so comments and trailing commas are fine.

Start from [`Packages/AjoissaCore/Examples/config.example.json5`](Packages/AjoissaCore/Examples/config.example.json5), which shows every setting, then check your file:

```sh
cd Packages/AjoissaCore
swift run ajoissa validate --config ~/.config/ajoissa/config.json5
```

`validate` lists every problem at once, each with where it is, and exits with 0 for a usable file, 1 for a file that breaks a rule and 66 for a file it cannot read. Settings it does not know, and settings written twice in the same object, are reported as errors, so a misspelled or repeated setting is not silently ignored.

## Layout

```
Ajoissa/                  Menu bar app (SwiftUI, MenuBarExtra)
AjoissaTests/             App tests
Packages/AjoissaCore/     The engine, a Swift package
  Sources/AjoissaCore/    Config, collectors, schedule logic, checks
  Sources/AjoissaCLI/     The `ajoissa` command line tool
  Examples/               Example config
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
