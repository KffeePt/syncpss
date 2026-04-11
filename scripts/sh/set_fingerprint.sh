#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/maintainer_id.sh"

maintainer_menu "$(cd "${SCRIPT_DIR}/../.." && pwd)"
