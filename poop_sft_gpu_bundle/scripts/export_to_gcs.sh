#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 gs://bucket/path-prefix [output_dir] [--workspace-dir <name/path>] [--shutdown]" >&2
  exit 2
fi

DEST_PREFIX="$1"
shift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_PARENT_DIR="$(cd "$BASE_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/workspace.sh"
GLOBAL_CFG_FILE="${POOPTRAIN_GLOBAL_CONFIG_DIR:-$HOME/.config/pooptrain}/workspace.env"
DEFAULT_WORKSPACE_DIR="$BUNDLE_PARENT_DIR/poopworkspace"
WORK_DIR_INPUT="${POOPTRAIN_WORKSPACE_DIR:-}"
WORK_DIR_INPUT="$(pt_load_workspace_input "$WORK_DIR_INPUT" "$GLOBAL_CFG_FILE")"
OUT_DIR=""
SHUTDOWN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir=*)
      WORK_DIR_INPUT="${1#*=}"
      shift
      ;;
    --workspace-dir)
      [[ $# -ge 2 ]] || { echo "[ERROR] --workspace-dir needs a value" >&2; exit 2; }
      WORK_DIR_INPUT="$2"
      shift 2
      ;;
    --shutdown)
      SHUTDOWN=1
      shift
      ;;
    *)
      if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="$1"
        shift
      else
        echo "[ERROR] unknown arg: $1" >&2
        exit 2
      fi
      ;;
  esac
done

WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
if [[ -z "$OUT_DIR" ]]; then
  if [[ -f "$WORK_DIR/last_run.env" ]]; then
    # shellcheck disable=SC1091
    source "$WORK_DIR/last_run.env" >/dev/null 2>&1 || true
    if [[ -n "${LAST_OUTPUT_DIR:-}" ]]; then
      OUT_DIR="$LAST_OUTPUT_DIR"
    fi
  fi
fi
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$WORK_DIR/output_poop_sft"
fi

TS="$(date +%Y%m%d_%H%M%S)"
STAGE_DIR="$WORK_DIR/export_stage_$TS"
PKG="$WORK_DIR/poop_sft_artifacts_$TS.tar.gz"

command -v gsutil >/dev/null 2>&1 || { echo "[ERROR] gsutil not found" >&2; exit 2; }
[[ -d "$OUT_DIR" ]] || { echo "[ERROR] output dir not found: $OUT_DIR" >&2; exit 2; }
[[ "$DEST_PREFIX" =~ ^gs://[^/]+(/.*)?$ ]] || { echo "[ERROR] invalid gcs path: $DEST_PREFIX" >&2; exit 2; }

mkdir -p "$STAGE_DIR"
cp -r "$OUT_DIR" "$STAGE_DIR/output_poop_sft"
if [[ -f "$WORK_DIR/last_run.env" ]]; then
  # shellcheck disable=SC1091
  source "$WORK_DIR/last_run.env" >/dev/null 2>&1 || true
  if [[ -n "${LAST_TRAIN_YAML:-}" ]] && [[ -f "${LAST_TRAIN_YAML:-}" ]]; then
    cp -f "$LAST_TRAIN_YAML" "$STAGE_DIR/train_poop_sft_lora.yaml" 2>/dev/null || true
  fi
fi
cp -f "$WORK_DIR/configs/train_poop_sft_lora.yaml" "$STAGE_DIR/" 2>/dev/null || true
cp -f "$WORK_DIR/last_run.env" "$STAGE_DIR/" 2>/dev/null || true

# Export the actual dataset used in the latest run if metadata exists.
if [[ -f "$WORK_DIR/last_run.env" ]]; then
  # shellcheck disable=SC1091
  source "$WORK_DIR/last_run.env"
  if [[ -n "${LAST_DATA_FILE:-}" ]] && [[ -f "${LAST_DATA_FILE:-}" ]]; then
    cp -f "$LAST_DATA_FILE" "$STAGE_DIR/$(basename "$LAST_DATA_FILE")"
    echo "[INFO] included training dataset: $LAST_DATA_FILE"
  fi
fi

# Fallback copies for reproducibility.
cp -f "$WORK_DIR/merged_dataset.jsonl" "$STAGE_DIR/" 2>/dev/null || true
cp -f "$BASE_DIR/data/instructions_gpt_94_v2.jsonl" "$STAGE_DIR/" 2>/dev/null || true

tar -czf "$PKG" -C "$STAGE_DIR" .
OBJ="$DEST_PREFIX/poop_sft_artifacts_$TS.tar.gz"

echo "[INFO] upload -> $OBJ"
gsutil -m cp "$PKG" "$OBJ"
gsutil ls "$OBJ"

echo "[OK] uploaded: $OBJ"

if [[ "$SHUTDOWN" -eq 1 ]]; then
  echo "[INFO] shutdown in 5s"
  sleep 5
  sudo shutdown -h now
fi
