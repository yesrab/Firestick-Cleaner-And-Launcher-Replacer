#!/usr/bin/env bash
# Firestick Cleanup - macOS entry point.
# All logic lives in ../common/firestick-cleanup.sh; this wrapper only tells it
# where the bundled adb and the log/state files live. Run with --help for options.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSC_PLATFORM_DIR="$DIR" FSC_ENTRY="$0" exec bash "$DIR/../common/firestick-cleanup.sh" "$@"
