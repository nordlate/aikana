# Ajoissa

A macOS menu bar app that answers one question: did everything that should have run actually run, on all my machines?

Ajoissa watches scheduled jobs (launchd on Macs, systemd timers and cron on Linux over SSH). You declare in a config file what is expected to run, where, when, and what counts as success. Ajoissa reports jobs that failed, jobs that never ran, and jobs that exited cleanly but did not produce their result.

"Ajoissa" is Finnish for "on time".

## Status

Early. For launchd jobs on this Mac, `ajoissa status` now gives a verdict on each job: whether the run that was last due happened, failed or is missing. Outcome checks are described in the config but not run yet, jobs on other machines are not read, and the app shows an empty menu bar panel. The plan is in the issues, in three milestones: one Mac, other machines, release.

## Config

Ajoissa reads `~/.config/ajoissa/config.json5`. Another file can be named with `--config <path>` or the `AJOISSA_CONFIG` environment variable. The format is JSON5, so comments and trailing commas are fine.

Start from [`Packages/AjoissaCore/Examples/config.example.json5`](Packages/AjoissaCore/Examples/config.example.json5), which shows every setting, then check your file:

```sh
cd Packages/AjoissaCore
swift run ajoissa validate --config ~/.config/ajoissa/config.json5
```

`validate` lists every problem at once, each with where it is, and exits with 0 for a usable file, 1 for a file that breaks a rule and 66 for a file it cannot read. Settings it does not know, and settings written twice in the same object, are reported as errors, so a misspelled or repeated setting is not silently ignored.

## What Ajoissa runs and reads

Ajoissa only reads. On this Mac it runs one command and reads one kind of file:

- `/bin/launchctl print gui/<your user id>/<label>` or `/bin/launchctl print system/<label>`, for each launchd job in your config. The label is refused unless it is one plain word.
- The plist files in `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons`, to find each job's timetable and log paths, and the plist launchd says a job was loaded from.
- The modification time of each job's log files (never their contents), and when this Mac last woke or started.

```sh
cd Packages/AjoissaCore
swift run ajoissa status --config ~/.config/ajoissa/config.json5
```

## How a job is judged

Each time Ajoissa looks at a job it asks one question: is there a scheduled time that no run accounts for? A run that is seen accounts for every scheduled time up to that moment. The verdict is about the oldest scheduled time still open, so a job that has stopped is reported once and stays reported until it runs again.

| Verdict | Meaning |
| --- | --- |
| `ok` | Every scheduled time so far is accounted for, and nothing about the last run failed. |
| `running` | The job is running now. |
| `waiting` | A run is due and still within its grace period, or no run has been due since Ajoissa started watching. |
| `failed` | The last run exited with an error or was killed, a check failed, or the job cannot run at all (not loaded, or not found). |
| `missed` | A run was due, its grace period is over, and there is no sign of it. It stays missed until a run is seen. |
| `unknown` | The job's state could not be read just now. This says nothing about the job. |
| `stale` | The state has been unreadable for a day. |
| `hostOffline` | The machine the job runs on cannot be reached. |

Things worth knowing:

- **Evidence of a run** is the scheduler's run count going up, the job's log file being written, or a check that proves it (a file newer than the scheduled time).
- **Grace** (`grace` in the config, 30 minutes by default) is how long after its scheduled time a run may still appear before it counts as missed.
- **Sleep.** launchd makes up for scheduled times that passed while the Mac slept with one run on wake. The grace period then counts from the wake, and that one run accounts for all of them, so a job is not reported as missed the moment the lid opens after a weekend.
- **Jobs on an interval** have no scheduled times. They are missed when the interval plus the grace has passed since the last run that was seen. Time asleep does not count.
- **Nothing is judged in hindsight.** A run that was due before Ajoissa first saw the job, or before its timetable changed, is not called missed. Evidence that it did happen is still believed.
- **History** is kept in `~/Library/Application Support/Ajoissa/history.json` (or the file `AJOISSA_HISTORY` names). launchd keeps no history of its own, so this file is what makes "the run count went up since last time" possible. A history file that cannot be read stops Ajoissa instead of being replaced.

### Limits

- **Switched off at the scheduled time.** launchd does not make up for a time that passed while the Mac was off. Ajoissa reports that as missed once the grace after starting is over. It is true, even though nothing is wrong with the job.
- **Looking only now and then.** The run count has no timestamps. When Ajoissa has not looked for a while, it compares how many runs started with how many were scheduled. A run started by hand in that gap can then stand in for a scheduled one that did not happen, and a reload after an unseen run can hide it. With the app looking every minute this does not arise.
- **Log files** count as evidence when they are written. A log that something else also writes to makes a job look as if it ran.
- **A timetable with both calendar times and an interval** is judged by its calendar times only, and the interval's runs account for them.
- **A plist edited but not reloaded.** The timetable is read from the file, while launchd keeps the one from when it loaded the job.
- **Both a day of the month and a weekday** in one launchd calendar entry are read as "both must match".
- **After the time zone changes**, scheduled times from before the change are read in the new zone.

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
