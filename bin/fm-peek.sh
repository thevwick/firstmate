#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

RAW_TARGET=$1
T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
N=${2:-40}

# A metaless target (e.g. firstmate's own primary pane, which is not a crewmate
# and carries no state/<id>.meta) resolves its backend from the live runtime,
# not a blind tmux assumption; if nothing resolves, fm_backend_of_selector
# errors and we surface a clear, actionable message rather than dispatching to a
# nonexistent tmux socket. The || guard keeps the message ours under `set -e`.
if ! BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE"); then
  echo "error: cannot peek '$RAW_TARGET' (resolved target '$T'): no backend could be resolved for this metaless target" >&2
  exit 1
fi
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
