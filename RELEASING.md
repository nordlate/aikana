# Releasing

How a version of Aikana gets out. The plan, and what is still to come (signed disk image, automatic updates), is in issue #32. This file grows with it.

## Versions

Three numbers must agree, and only a bump PR changes them:

| What | Where | Example |
|---|---|---|
| Version (`MARKETING_VERSION`) | `Aikana.xcodeproj`, Debug and Release | `0.2.0` |
| Engine version (`AikanaCore.version`) | `Packages/AikanaCore/Sources/AikanaCore/AikanaCore.swift` | `0.2.0` |
| Build number (`CURRENT_PROJECT_VERSION`) | `Aikana.xcodeproj`, Debug and Release | `2` |

The build number is a whole number that goes up by one with every release. The updater decides whether a download is newer by the build number, not by the version, so a release that does not raise it is never offered to anyone.

A bump PR changes these three and nothing else. Feature and fix PRs never touch them.

## Checking

```sh
scripts/check-version.sh            # the numbers agree
scripts/check-version.sh v0.2.0     # and the tree is ready to be released as v0.2.0
```

Without a tag it fails unless the version is the same `X.Y.Z` everywhere and the build number is the same whole number in both configurations. With a tag it also fails unless the tag is `v` plus the version and both the version and the build number are higher than in the latest other `v*` tag.

## Making a release

1. Open a bump PR: raise the version and the build number. Run `scripts/check-version.sh v<new version>` before pushing.
2. Merge it, then tag the merge commit on `main`:

   ```sh
   git switch main && git pull
   scripts/check-version.sh v0.2.0
   git tag -a v0.2.0 -m "Aikana 0.2.0"
   git push origin v0.2.0
   ```

3. Create the GitHub release for the tag, with notes on what changed.

Building, signing and notarizing the download are added here when that lands (#32).

## Secrets

None of these is ever committed; `.gitignore` refuses the usual file names (`*.p12`, `*.p8`, `AuthKey_*`). Everything else the release uses (team ID, bundle IDs, the update feed URL, the updater's public key, the scripts) is public and belongs in the repo.

| Secret | Used for | Kept in | Backup | If it leaks or is lost |
|---|---|---|---|---|
| Developer ID Application certificate and its private key | Signing the app and the disk image | Login Keychain (exported `.p12` only for CI) | Exported `.p12` in offline storage | Revoke it in the developer account and create a new one. |
| App Store Connect API key (`.p8`), key ID, issuer ID | Notarization | `notarytool` Keychain profile `aikana-notary` | The `.p8` in offline storage (it can be downloaded only once) | Revoke the key in App Store Connect and make a new one. |
| Updater signing key (Sparkle EdDSA private key) | Signing each update so installed copies accept it | Login Keychain | Exported with `generate_keys -x` to offline storage | Whoever has it can send an update every installed copy accepts. Without it installed copies cannot be sure an update is ours, and may stop accepting them. Keep the backup. |

In CI they live in GitHub encrypted secrets, in a protected `release` environment that only tag builds can use.
