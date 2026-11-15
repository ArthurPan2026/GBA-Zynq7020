#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
flow_python="${FLOW_PYTHON:-$HOME/.local/bin/python3}"
if [[ ! -x "$flow_python" ]]; then
  flow_python="$(command -v python3.15 || command -v python3 || true)"
fi
if [[ -z "$flow_python" || ! -x "$flow_python" ]]; then
  echo "Python 3.15 is required; install the pinned .python-version runtime." >&2
  exit 2
fi
vitis_root="${VITIS_ROOT:-/tools/AMDDesignTools/2025.2.1/Vitis}"
vitis_bin="${VITIS_BIN:-$vitis_root/bin/vitis}"
if [[ ! -x "$vitis_bin" ]]; then
  echo "Vitis executable is missing: $vitis_bin" >&2
  exit 2
fi
exec "$flow_python" "$repo_root/tools/flow.py" \
  --vitis "$vitis_bin" build --stage app "$@"
