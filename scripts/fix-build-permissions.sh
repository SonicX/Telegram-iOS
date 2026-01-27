#!/bin/sh
# Fix "Permission denied" when building for device (iphoneos).
# Bazel creates framework outputs read-only; Xcode needs to write Info.plist there.
# Run this before building for a physical device, or when you see:
#   error: unable to write file '.../Info.plist': Permission denied (13)

set -e
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Swiftgram-"*
BAZEL_OUT="/var/tmp/_bazel_$(whoami)"/*/rules_xcodeproj.noindex/build_output_base/execroot/_main/bazel-out

for dir in $DERIVED; do
  [ -d "$dir" ] && chmod -R u+w "$dir/Build/Products" 2>/dev/null || true
done
for dir in $BAZEL_OUT; do
  [ -d "$dir" ] && chmod -R u+w "$dir" 2>/dev/null || true
done
echo "Permissions updated. Try building for device again."
