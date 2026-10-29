#!/bin/bash
# Format check, clang-tidy, and the Clang static analyzer for all Objective-C sources.
# Install the pinned tools with: pip install --require-hashes -r Scripts/lint-requirements.txt
set -euo pipefail
cd "$(dirname "$0")/.."
FILES=(Sources/main.m Sources/Focus.m Sources/Focus.h Sources/Update.m Sources/Update.h Scripts/generate-icon.m Scripts/generate-dmg-background.m)
SOURCES=(Sources/main.m Sources/Focus.m Sources/Update.m Scripts/generate-icon.m Scripts/generate-dmg-background.m)
SDK="$(xcrun --show-sdk-path)"
if [[ "${1:-}" == --fix ]]; then
  clang-format -i "${FILES[@]}"
  exit 0
fi
clang-format --dry-run --Werror "${FILES[@]}"
clang-tidy --quiet --extra-arg="-isysroot$SDK" "${SOURCES[@]}"
for file in "${SOURCES[@]}"; do
  # BOOL is signed char on x86_64, so check both slices of the universal build.
  for arch in arm64 x86_64; do
    xcrun clang @compile_flags.txt -Werror -fsyntax-only -arch "$arch" "$file"
  done
  xcrun clang --analyze @compile_flags.txt -Werror -Xanalyzer -analyzer-output=text \
    -o /dev/null "$file"
done
echo "Lint passed"
