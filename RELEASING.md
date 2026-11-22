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

3. Build the disk image from the tag:

   ```sh
   scripts/release.sh 0.2.0
   ```

   It checks the versions, archives, exports with Developer ID, notarizes and staples the app, puts it in a disk image with an Applications link, signs, notarizes and staples the image, and verifies all of it. The result is `build/release/0.2.0/Aikana-0.2.0.dmg`; its SHA-256 is printed at the end. If Xcode is not the selected developer directory, prefix it with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

4. Try the image as a user gets it: upload it to a draft release, download it with a browser (so it is quarantined), open it, drag the app to Applications and start it. The only prompt should be the usual one for an app downloaded from the internet.
5. Publish the GitHub release for the tag, with the image attached and notes on what changed.
6. `release.sh` also added the new version to `appcast.xml` in the working tree, signed with the update key and pointing at `…/releases/download/v0.2.0/Aikana-0.2.0.dmg`. Open a PR with only that change and merge it **after** the release is published, so the feed never names a download that is not there yet. Installed copies see the update once it is on `main`.

The feed URL (`SUFeedURL` in `Aikana/Info.plist`) is built into every copy ever shipped. Keep `appcast.xml` at the root of `main`.

## One-time setup on the Mac that releases

- The team's **Developer ID Application** certificate, with its private key, in the login Keychain. `release.sh` finds it by team ID, so no name is written in the repo.
- A **notarytool profile** from an App Store Connect API key (Users and Access → Integrations, Developer access is enough):

  ```sh
  xcrun notarytool store-credentials aikana-notary --key <path to AuthKey_XXXX.p8> --key-id <key ID> --issuer <issuer ID>
  ```

  `xcrun notarytool history --keychain-profile aikana-notary` checks it. Another profile name can be given with `AIKANA_NOTARY_PROFILE`.
- The **update signing key** (Sparkle EdDSA), in the login Keychain under the account `aikana` (or `AIKANA_SPARKLE_ACCOUNT`). Sparkle's tools come with the package; after a build they are in `build/SourcePackages/artifacts/sparkle/Sparkle/bin/`:

  ```sh
  generate_keys --account aikana          # makes the key once, prints the public half
  generate_keys --account aikana -x <file> # exports the private key, for the offline backup
  ```

  The public half is `SUPublicEDKey` in `Aikana/Info.plist`. `release.sh` refuses to build when the key in the Keychain does not match it.

## Secrets

None of these is ever committed; `.gitignore` refuses the usual file names (`*.p12`, `*.p8`, `AuthKey_*`). Everything else the release uses (team ID, bundle IDs, the update feed URL, the updater's public key, the scripts) is public and belongs in the repo.

| Secret | Used for | Kept in | Backup | If it leaks or is lost |
|---|---|---|---|---|
| Developer ID Application certificate and its private key | Signing the app and the disk image | Login Keychain (exported `.p12` only for CI) | Exported `.p12` in offline storage | Revoke it in the developer account and create a new one. |
| App Store Connect API key (`.p8`), key ID, issuer ID | Notarization | `notarytool` Keychain profile `aikana-notary` | The `.p8` in offline storage (it can be downloaded only once) | Revoke the key in App Store Connect and make a new one. |
| Updater signing key (Sparkle EdDSA private key) | Signing each update so installed copies accept it | Login Keychain | Exported with `generate_keys -x` to offline storage | Whoever has it can send an update every installed copy accepts. Without it installed copies cannot be sure an update is ours, and may stop accepting them. Keep the backup. |

In CI they live in GitHub encrypted secrets, in a protected `release` environment that only tag builds can use.
