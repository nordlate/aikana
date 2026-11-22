#!/bin/bash
# Checks that the version numbers agree before a release.
#
#   scripts/check-version.sh            the numbers agree
#   scripts/check-version.sh v0.2.0     and the tree is ready to be released as this tag
#
# Always fails unless:
# - every MARKETING_VERSION in the Xcode project is the same X.Y.Z,
# - AikanaCore.version is that same X.Y.Z,
# - every CURRENT_PROJECT_VERSION (the build number) is the same whole number.
# With a tag, also fails unless:
# - the tag is v<X.Y.Z>,
# - the version and the build number are both higher than in the latest
#   other v* tag. Sparkle decides whether an update is newer by the build
#   number (CFBundleVersion), not by the version.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

project="Aikana.xcodeproj/project.pbxproj"
core="Packages/AikanaCore/Sources/AikanaCore/AikanaCore.swift"
tag="${1:-}"
problems=0

fail() {
    echo "error: $*" >&2
    problems=$((problems + 1))
}

# The distinct values of one build setting in a project file read from stdin.
setting_values() {
    sed -n "s/^[[:space:]]*$1 = \"\{0,1\}\([^\";]*\)\"\{0,1\};$/\1/p" | sort -u
}

marketing="$(setting_values MARKETING_VERSION < "$project")"
build="$(setting_values CURRENT_PROJECT_VERSION < "$project")"
core_version="$(sed -n 's/^[[:space:]]*public static let version = "\([^"]*\)"$/\1/p' "$core")"

if [ -z "$marketing" ]; then
    fail "no MARKETING_VERSION in $project"
elif [ "$(printf '%s\n' "$marketing" | wc -l)" -ne 1 ]; then
    fail "MARKETING_VERSION differs between configurations in $project: $(echo $marketing)"
elif ! printf '%s' "$marketing" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "MARKETING_VERSION is \"$marketing\", expected X.Y.Z"
fi

if [ -z "$build" ]; then
    fail "no CURRENT_PROJECT_VERSION in $project"
elif [ "$(printf '%s\n' "$build" | wc -l)" -ne 1 ]; then
    fail "CURRENT_PROJECT_VERSION differs between configurations in $project: $(echo $build)"
elif ! printf '%s' "$build" | grep -Eq '^[1-9][0-9]*$'; then
    fail "CURRENT_PROJECT_VERSION is \"$build\", expected a whole number above 0"
fi

if [ -z "$core_version" ]; then
    fail "no AikanaCore.version in $core"
elif [ "$problems" -eq 0 ] && [ "$core_version" != "$marketing" ]; then
    fail "AikanaCore.version is $core_version but MARKETING_VERSION is $marketing"
fi

if [ -n "$tag" ] && [ "$tag" != "v$marketing" ]; then
    fail "tag is $tag but the version is $marketing (expected v$marketing)"
fi

# The latest v* tag other than the one being checked: the previous release.
previous=""
if [ -n "$tag" ]; then
    previous="$(git tag --list 'v*' | grep -Fvx -- "$tag" | sed 's/^v//' | sort -V | tail -n 1 || true)"
fi

if [ "$problems" -eq 0 ] && [ -n "$previous" ]; then
    previous_build="$(git show "v$previous:$project" | setting_values CURRENT_PROJECT_VERSION | tail -n 1)"
    newest="$(printf '%s\n%s\n' "$previous" "$marketing" | sort -V | tail -n 1)"
    if [ "$marketing" = "$previous" ] || [ "$newest" != "$marketing" ]; then
        fail "version $marketing is not higher than the last release, v$previous"
    fi
    if [ -n "$previous_build" ] && [ "$build" -le "$previous_build" ]; then
        fail "build number $build is not higher than $previous_build in v$previous; raise CURRENT_PROJECT_VERSION"
    fi
fi

if [ "$problems" -ne 0 ]; then
    exit 1
fi

if [ -z "$tag" ]; then
    echo "version $marketing, build $build"
elif [ -n "$previous" ]; then
    echo "ready for $tag: version $marketing, build $build (last release v$previous)"
else
    echo "ready for $tag: version $marketing, build $build (no earlier release)"
fi
