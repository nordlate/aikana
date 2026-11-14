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
cd Packages/AjoissaCore && swift run ajoissa status --config Examples/config.example.json5

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
  Features/               Watch/ (WatchModel), StatusMenu/ (panel, list, footer), JobDetail/,
                          Notifications/ (SystemNotifier, PanelOpener)
AjoissaTests/             XCTest, hosted in the app
Packages/AjoissaCore/     The engine
  Sources/AjoissaCore/    Config/ (model, validating loader), Launchd/ (plist reader, launchctl parser, collector),
                          Evaluation/ (Timetable, Evidence, JobEvaluator, JobRecord, History),
                          Checks/ (HostAccess, LocalHost, CheckRunner, CheckState, JobAssessor),
                          Watch/ (JobReport, JobWatch, WatchSession, LogTail, Alert),
                          Remote/ (RemoteShell, RemoteCommands, RemoteHost, ShellQuoting),
                          Support/ (CommandRunner). Later: systemd and cron collectors
  Sources/AjoissaCLI/     `ajoissa` command line tool (product name `ajoissa`)
  Tests/AjoissaCoreTests/ XCTest
```

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`: new files under `Ajoissa/` and `AjoissaTests/` are included without editing the project file. The package picks up files under its `Sources/` and `Tests/` folders on its own.

## Rules

- **AjoissaCore is Foundation only.** No AppKit, SwiftUI or UserNotifications in it, and it never imports the app. It will be published as a separate package; keep its public API deliberate and documented.
- **Logic goes in AjoissaCore, presentation in the app.** If it can be tested without a window, it belongs in the package.
- **Read-only.** Ajoissa observes jobs. Do not add code that starts, stops, loads, unloads or edits a job, a plist, a unit or a crontab.
- **Nothing personal in the repo.** No real host names, user names, paths or job names in sources, tests, fixtures or examples. Use made-up ones.
- **Every script run on another machine is in `RemoteCommands.swift`, and nowhere else.** Remote work goes through `RemoteShell`, which runs `ssh … -- <alias> /bin/sh` and sends the script on standard input; nothing from the config is ever on the command line the remote login shell reads. A config value enters a script only through `ShellQuoting.quote`. Scripts are POSIX sh, only read (except running a `command` check), and end by reporting a status after `ajoissa:` on stderr. A new or changed script needs: tests that run it through real `/bin/sh` and `/bin/dash` against a temp folder (`RemoteHostTestCase`), with hostile names, and a row in the README table under "On other machines". Do not add ssh options beyond those in `RemoteShell.sshArguments` without listing them in the README.
- **A machine that cannot be reached is `hostOffline`; one that answers but cannot be relied on (clock off, unexpected answer) is `unknown`.** Neither is ever `missed`, `failed` or `ok`, and no checks run. Changes to offline handling need timeline tests in `JobEvaluatorHostTests`.
- **Time is injected.** Schedule and evaluation logic takes the current time and its evidence as parameters; no `Date()` and no I/O inside it.
- **`JobEvaluator` decides every alert.** It is a pure function of the job, the evidence, the previous record, the time and the calendar. Any change to it needs a scenario test in `Tests/AjoissaCoreTests/Evaluation/` written as a timeline (`Scenario`), and must keep these properties: the verdict is about the oldest scheduled time no run accounts for, so a stopped job turns `missed` once and stays `missed` (no flapping, however often it is scheduled); an absent run is `missed` only after its deadline and only if it was due while the job was loaded and being watched; scheduled times slept through count as one; the moment a grace period counts from is settled when a scheduled time is first found open, so a later wake never turns `missed` back into `waiting`; a run in progress is a run; unreadable state or an unreadable timetable is `unknown`, never `ok`, `missed` or `failed`; evidence from the future is ignored; a failing check does not fail a job whose run still has time. The known limits are listed in the README under "Limits"; update that list when one is closed or a new one is found.
- **Checks reach the job's machine only through `HostAccess`.** `CheckRunner` never touches `FileManager` or `Process`; `LocalHost` does it for this Mac and an SSH host will do it for others, so a check behaves the same everywhere. A check has three results, and "could not be carried out" is never reported as failed. Every check type needs tests for pass, fail and could-not-run, with the exact message. A passing check may claim to prove a run (`provesRunAt`) only with the time the proof is from; the evaluator credits the run at that time, never at "now".
- **`JobAssessor.assess` is the one way to look at a job.** It evaluates, runs the checks against the run the evaluation expects, and evaluates again. Callers (the CLI, later the app) do not call `CheckRunner` or `JobEvaluator` themselves.
- **`WatchSession.round` is one look at everything**: read the config, read the history, look at every job on every machine (`JobWatch`), save. The CLI and the app both call it and nothing else; the app's `WatchModel` only decides when, and turns the outcome into what is shown. What a view shows about a job comes from its `JobReport`; add a field there, with a test, before reaching into the engine from a view.
- **`AlertPlanner` decides what the user is told, once per incident.** It reads only the states the evaluator gave and keeps what was told in `JobRecord.alerted`. Only a round asked to `announce` runs it; the CLI never does, or it would use up what the app has yet to tell. The app turns its alerts into one `Announcement` per look and hands it to `SystemNotifier`; whether to tell at all (the menu switches) is the model's part. A new kind of alert needs planner tests for no-repeat, recovery and grouping.
- **The app never watches while it hosts tests.** `AjoissaApp` does not start the model under XCTest, so a test run cannot read the user's jobs or write the user's history. `WatchModel` takes everything from outside through `WatchModel.Environment`; tests pass their own.
- **Try the app on scratch files.** Launch the built binary with `AJOISSA_CONFIG` and `AJOISSA_HISTORY` set, not against the user's own config and history.
- **Collectors gather, the evaluator judges.** A collector turns what it read into `Evidence` and never decides a `JobState` itself.
- **Not sandboxed, hardened runtime on.** Do not enable the App Sandbox.
- **The config is validated in one place.** `ConfigLoader` is the only way to get a `Config`, and it reports every problem with a path and a message written for a person. A new setting needs: the model, the parser, a test per rule with the exact message, and an entry in `Packages/AjoissaCore/Examples/config.example.json5`. Unknown settings are errors.
- **Values that reach another program must stay one harmless word.** Host aliases, launchd labels and unit names may only contain letters, digits and a few listed punctuation characters, and may not start with `-`: they end up as arguments to `launchctl` and `ssh`, and ssh hands its command to a remote shell. Free text (paths, patterns, cron text) must be a single line. Do not loosen these without a test that shows the value is quoted safely where it is used.
- **Other programs are reached only through `CommandRunner`.** Never call `Process` elsewhere. Arguments are a list, never a shell string, and every command has a timeout. Tests use `FakeCommandRunner`.
- **Every command Ajoissa runs is listed in the README** ("What Ajoissa runs and reads"). Add to that list in the same change that adds a command.
- **`launchctl print` output is not a stable format.** `LaunchctlPrintParser` takes what it recognises and leaves the rest `nil`; it must never fail on an unknown line. When the format changes, capture real output from a throwaway `com.example.*` job, strip everything personal, add it under `Tests/AjoissaCoreTests/Launchd/Fixtures/` and update the parser.
- **"Could not be read" is not "is broken".** A collector reports `unknown` with a reason when it cannot tell; it never guesses a job's state.
- **Tests are XCTest.** The command line target is named `AjoissaCLI` so its module does not collide with the app module `Ajoissa` on a case-insensitive disk.

## Tasks

Tasks are GitHub issues in `nordlate/ajoissa`. Versions change only in a separate bump PR; feature and fix PRs do not touch them.
