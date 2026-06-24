#!/usr/bin/env bash
# Enchaîne download + import. Lance ensuite ./serve.sh manuellement.
set -euo pipefail
cd "$(dirname "$0")"
./download.sh
./import.sh
echo "BUILD_COMPLETE"
