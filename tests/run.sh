#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$ROOT/tests/monitor.test.sh"
node --test "$ROOT/tests/dashboard.test.mjs"
