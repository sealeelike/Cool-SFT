#!/usr/bin/env bash
set -euo pipefail

# Monitor HuggingFace Trainer state and print ETA.
# Usage:
#   bash scripts/monitor_hf_eta.sh /path/to/output_dir [interval_sec]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_PARENT_DIR="$(cd "$BASE_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/workspace.sh"
GLOBAL_CFG_FILE="${POOPTRAIN_GLOBAL_CONFIG_DIR:-$HOME/.config/pooptrain}/workspace.env"
DEFAULT_WORKSPACE_DIR="$BUNDLE_PARENT_DIR/poopworkspace"
WORK_DIR_INPUT="${POOPTRAIN_WORKSPACE_DIR:-}"
WORK_DIR_INPUT="$(pt_load_workspace_input "$WORK_DIR_INPUT" "$GLOBAL_CFG_FILE")"
WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
OUT_DIR="${1:-$WORK_DIR/output_poop_sft}"
INTERVAL="${2:-15}"

if [[ $# -lt 1 ]] && [[ -f "$WORK_DIR/last_run.env" ]]; then
  # shellcheck disable=SC1090
  source "$WORK_DIR/last_run.env" >/dev/null 2>&1 || true
  if [[ -n "${LAST_OUTPUT_DIR:-}" ]]; then
    OUT_DIR="$LAST_OUTPUT_DIR"
  fi
fi

STATE_FILE="$OUT_DIR/trainer_state.json"

if [[ ! -d "$OUT_DIR" ]]; then
  echo "[ERROR] output dir not found: $OUT_DIR" >&2
  exit 2
fi

echo "[INFO] monitoring: $OUT_DIR"
echo "[INFO] state file: $STATE_FILE"

while_true() {
  while true; do
    if [[ -f "$STATE_FILE" ]]; then
      python3 - "$STATE_FILE" <<'PY'
import json,sys,time
p=sys.argv[1]
now=time.time()
try:
    d=json.load(open(p,encoding='utf-8'))
except Exception as e:
    print(f"[WARN] failed to read state: {e}")
    raise SystemExit(0)

global_step=int(d.get('global_step') or 0)
max_steps=int(d.get('max_steps') or 0)
best=d.get('best_metric')
logs=d.get('log_history') or []

step_per_sec=None
for item in reversed(logs):
    if isinstance(item,dict) and 'train_runtime' in item and 'train_steps_per_second' in item:
        try:
            step_per_sec=float(item['train_steps_per_second'])
            break
        except Exception:
            pass

if step_per_sec is None:
    # fallback from recent logs with elapsed time
    recent=[x for x in logs if isinstance(x,dict) and 'step' in x and 'epoch' in x]
    if len(recent)>=2:
        a,b=recent[-2],recent[-1]
        ds=(b.get('step',0)-a.get('step',0))
        # no timestamp in history usually, so skip

remain=max(0,max_steps-global_step) if max_steps>0 else -1
if step_per_sec and remain>=0:
    eta_sec=remain/step_per_sec if step_per_sec>0 else -1
else:
    eta_sec=-1

def fmt(sec):
    if sec is None or sec<0:
        return 'unknown'
    sec=int(sec)
    h=sec//3600
    m=(sec%3600)//60
    s=sec%60
    return f"{h:02d}:{m:02d}:{s:02d}"

ratio=(global_step/max_steps*100.0) if max_steps>0 else 0.0
line=f"step={global_step}/{max_steps} ({ratio:.1f}%)"
if step_per_sec:
    line+=f" | speed={step_per_sec:.3f} step/s"
line+=f" | eta={fmt(eta_sec)}"
if best is not None:
    line+=f" | best_metric={best}"
print(line)
PY
    else
      echo "[WAIT] trainer_state.json not created yet..."
    fi
    sleep "$INTERVAL"
  done
}

while_true
