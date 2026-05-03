#!/bin/sh
# Removes write protection from build outputs that Bazel emits read-only and
# that Xcode then needs to overwrite — e.g. `Info.plist` of frameworks, the
# `.swiftmodule` copies into `Build/Products`, etc.  Without this, you hit
# errors like:
#
#   error: unable to write file '.../Info.plist': Permission denied (13)
#   error: copy(.../SwiftSignalKit.swiftmodule, ...): No such file or directory (2)
#
# This script runs automatically before every Xcode build because the
# `xcodeproj` rule in `Telegram/BUILD` references it via its `pre_build`
# attribute.  It can also be invoked manually:
#
#   sh scripts/fix-build-permissions.sh
#
# Always exits 0 — failing here would mask the real build error.

set +e

# Xcode runs scheme pre-actions for every action (build / index / clean / …).
# Only do work for real builds.
if [ -n "$ACTION" ] && [ "$ACTION" != "build" ]; then
    exit 0
fi

dirs=""

add_dir() {
    [ -n "$1" ] && [ -d "$1" ] && dirs="$dirs
$1"
}

# Xcode-provided locations for the current build (most precise; covers any
# DerivedData path the user has configured, including custom ones).
add_dir "$OBJROOT"
add_dir "$SYMROOT"
add_dir "$BUILD_DIR"
if [ -n "$OBJROOT" ]; then
    # `<DerivedData>/Build` — covers both Products and Intermediates.
    add_dir "${OBJROOT%/Intermediates.noindex}"
fi

# Bazel output base used by rules_xcodeproj.  Bazel marks generated files
# read-only; the subsequent xcodebuild pass needs to copy/rewrite some of
# them, which fails without u+w.
for d in /var/tmp/_bazel_$(whoami)/*/rules_xcodeproj.noindex/build_output_base/execroot/_main/bazel-out; do
    add_dir "$d"
done

# Standard DerivedData fallback for invocations outside Xcode (manual run).
if [ -z "$OBJROOT" ]; then
    for d in "$HOME/Library/Developer/Xcode/DerivedData"/Swiftgram-*; do
        add_dir "$d"
    done
fi

# De-duplicate while preserving order, then chmod each directory.
seen=""
printf '%s\n' "$dirs" | while IFS= read -r d; do
    [ -z "$d" ] && continue
    case "$seen" in
        *"|$d|"*) continue ;;
    esac
    seen="${seen}|$d|"
    chmod -R u+w "$d" 2>/dev/null
done

# Emit a single concise log line so the action is visible in build output.
if [ -n "$ACTION" ]; then
    printf 'fix-build-permissions: chmod u+w applied to bazel/DerivedData outputs\n'
fi
exit 0
