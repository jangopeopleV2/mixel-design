#!/usr/bin/env bash
# Separate Mac App Store build/package path. It never uploads or notarizes.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/mas_package.py" "$@"
