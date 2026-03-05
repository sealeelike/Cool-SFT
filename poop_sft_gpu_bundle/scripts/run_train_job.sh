#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_PARENT_DIR="$(cd "$BASE_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/workspace.sh"
source "$SCRIPT_DIR/lib/interactive.sh"
source "$SCRIPT_DIR/lib/data.sh"
source "$SCRIPT_DIR/lib/params.sh"
GLOBAL_CFG_DIR="${POOPTRAIN_GLOBAL_CONFIG_DIR:-$HOME/.config/pooptrain}"
GLOBAL_CFG_FILE="$GLOBAL_CFG_DIR/workspace.env"
DEFAULT_WORKSPACE_NAME="poopworkspace"
DEFAULT_WORKSPACE_DIR="$BUNDLE_PARENT_DIR/$DEFAULT_WORKSPACE_NAME"
WORK_DIR_INPUT="${POOPTRAIN_WORKSPACE_DIR:-}"
WORK_DIR_INPUT="$(pt_load_workspace_input "$WORK_DIR_INPUT" "$GLOBAL_CFG_FILE")"
WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"

ENV_CONFIG_FILE="${POOPTRAIN_CONFIG_FILE:-$WORK_DIR/train_config.env}"
if [[ -f "$ENV_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_CONFIG_FILE"
fi
WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "${POOPTRAIN_WORKSPACE_DIR:-$WORK_DIR}" "$DEFAULT_WORKSPACE_DIR")"
VENV_DIR="$WORK_DIR/venv"
LLF_DIR="$WORK_DIR/LLaMA-Factory"
DATA_FILE="$BASE_DIR/data/instructions_gpt_94_v2.jsonl"
CONFIG_DIR="$WORK_DIR/configs"
OUT_DIR="$WORK_DIR/output_poop_sft"
RUN_META_FILE="$WORK_DIR/last_run.env"
RUNS_DIR="$WORK_DIR/runs"
RUN_NAME="${POOPTRAIN_RUN_NAME:-}"
RUN_NAME_FROM_CLI=0
RUN_DIR=""
RUN_META_DETAIL_FILE=""
TMP_WORK_DIR="$WORK_DIR/tmp"
HF_HOME_DIR="$WORK_DIR/hf_home"
PIP_CACHE_DIR="$WORK_DIR/pip_cache"
XDG_CACHE_DIR="$WORK_DIR/.cache"
TORCH_HOME_DIR="$WORK_DIR/torch_home"
BASE_MODELS_DIR="$WORK_DIR/base_models"

MODEL_NAME="${POOPTRAIN_MODEL_NAME:-Qwen/Qwen2.5-0.5B}"
TEMPLATE_NAME="auto"
DATASET_NAME="poop_sft_zh"
MAX_STEPS="${POOPTRAIN_MAX_STEPS:-}"
NUM_TRAIN_EPOCHS="${POOPTRAIN_NUM_TRAIN_EPOCHS:-}"
MAX_SAMPLES=""
FORCE_TORCH_REINSTALL=0
GCS_PREFIX="${POOPTRAIN_GCS_PREFIX:-}"
GCS_FROM_CLI=0
SKIP_PRECHECK=0
LORA_TARGET="all"
LORA_R="${POOPTRAIN_LORA_R:-}"
LORA_ALPHA="${POOPTRAIN_LORA_ALPHA:-}"
RESUME_MODE="${POOPTRAIN_RESUME_MODE:-auto}"
DATA_MODE="${POOPTRAIN_DATA_MODE:-all}"
DATA_FROM_CLI=0
AUTO_SYNC_GCS=1
SYNC_EVERY_STEPS="${POOPTRAIN_SYNC_EVERY_STEPS:-}"
AUTO_CONFIRM=0
MODEL_FROM_CLI=0
WORKSPACE_FROM_CLI=0
INTERACTIVE_MODE=0
INTERACTIVE_MODE_SET=0
PREPARE_DEPS_MODE="auto"  # auto|always|never
ORIG_ARGC="$#"
VAL_SIZE="${POOPTRAIN_VAL_SIZE:-0.1}"
SEED="${POOPTRAIN_SEED:-42}"
CUTOFF_LEN="${POOPTRAIN_CUTOFF_LEN:-}"
LEARNING_RATE="${POOPTRAIN_LEARNING_RATE:-}"
BATCH_SIZE_OVERRIDE="${POOPTRAIN_BATCH_SIZE:-}"
GRAD_ACC_OVERRIDE="${POOPTRAIN_GRAD_ACC:-}"
SAVE_STEPS_OVERRIDE="${POOPTRAIN_SAVE_STEPS:-}"
EVAL_STEPS="${POOPTRAIN_EVAL_STEPS:-}"
SHUFFLE_DATA="${POOPTRAIN_SHUFFLE_DATA:-1}"
MAX_STEPS_SET=0
EPOCHS_SET=0
LORA_R_SET=0
LORA_ALPHA_SET=0
LEARNING_RATE_SET=0
CUTOFF_LEN_SET=0
if [[ -n "$MAX_STEPS" ]]; then
  MAX_STEPS_SET=1
fi
if [[ -n "$NUM_TRAIN_EPOCHS" ]]; then
  EPOCHS_SET=1
fi
if [[ -n "$LORA_R" ]]; then
  LORA_R_SET=1
fi
if [[ -n "$LORA_ALPHA" ]]; then
  LORA_ALPHA_SET=1
fi
if [[ -n "$LEARNING_RATE" ]]; then
  LEARNING_RATE_SET=1
fi
if [[ -n "$CUTOFF_LEN" ]]; then
  CUTOFF_LEN_SET=1
fi

# Repair common SSH TTY erase-key mismatch so Backspace works in prompts.
pt_fix_tty_erase

PYTHON_SYS_BIN="$(command -v python3 || command -v python || true)"
if [[ -z "$PYTHON_SYS_BIN" ]]; then
  echo "[ERROR] python3/python not found in PATH" >&2
  exit 2
fi

print_usage() {
  cat <<'EOF'
Usage:
  ./scripts/run_train_job.sh [options]

Common options:
  --model <hf_model_id>
  --workspace-dir <dir_or_name>
  --run-name <name>
  --gcs-prefix <gs://bucket/prefix>
  --resume <auto|never|path>
  --data-mode <all|single|selected>
  --data-file <file_or_dir>
  --num-train-epochs <float>
  --max-steps <int>
  --val-size <0|ratio|count>
  --seed <int>
  --cutoff-len <int>
  --learning-rate <float>
  --batch <int>
  --grad-acc <int>
  --save-steps <int>
  --eval-steps <int>
  --lora-r <int>
  --lora-alpha <int>
  --sync-every-steps <int|0|off>
  --no-auto-sync
  --prepare-deps <auto|always|never>
  --force-torch-reinstall
  --interactive / --no-interactive
  --yes
  --skip-precheck
  --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model=*)
      MODEL_NAME="${1#*=}"
      MODEL_FROM_CLI=1
      shift
      ;;
    --model)
      [[ $# -ge 2 ]] || { echo "[ERROR] --model needs a value" >&2; exit 2; }
      MODEL_NAME="$2"
      MODEL_FROM_CLI=1
      shift 2
      ;;
    --workspace-dir=*)
      WORK_DIR_INPUT="${1#*=}"
      WORKSPACE_FROM_CLI=1
      shift
      ;;
    --workspace-dir)
      [[ $# -ge 2 ]] || { echo "[ERROR] --workspace-dir needs a value" >&2; exit 2; }
      WORK_DIR_INPUT="$2"
      WORKSPACE_FROM_CLI=1
      shift 2
      ;;
    --run-name=*)
      RUN_NAME="${1#*=}"
      RUN_NAME_FROM_CLI=1
      shift
      ;;
    --run-name)
      [[ $# -ge 2 ]] || { echo "[ERROR] --run-name needs a value" >&2; exit 2; }
      RUN_NAME="$2"
      RUN_NAME_FROM_CLI=1
      shift 2
      ;;
    --template=*)
      TEMPLATE_NAME="${1#*=}"
      shift
      ;;
    --template)
      [[ $# -ge 2 ]] || { echo "[ERROR] --template needs a value" >&2; exit 2; }
      TEMPLATE_NAME="$2"
      shift 2
      ;;
    --max-steps=*)
      MAX_STEPS="${1#*=}"
      MAX_STEPS_SET=1
      EPOCHS_SET=0
      NUM_TRAIN_EPOCHS=""
      shift
      ;;
    --max-steps)
      [[ $# -ge 2 ]] || { echo "[ERROR] --max-steps needs a value" >&2; exit 2; }
      MAX_STEPS="$2"
      MAX_STEPS_SET=1
      EPOCHS_SET=0
      NUM_TRAIN_EPOCHS=""
      shift 2
      ;;
    --num-train-epochs=*)
      NUM_TRAIN_EPOCHS="${1#*=}"
      EPOCHS_SET=1
      MAX_STEPS_SET=0
      MAX_STEPS=""
      shift
      ;;
    --num-train-epochs)
      [[ $# -ge 2 ]] || { echo "[ERROR] --num-train-epochs needs a value" >&2; exit 2; }
      NUM_TRAIN_EPOCHS="$2"
      EPOCHS_SET=1
      MAX_STEPS_SET=0
      MAX_STEPS=""
      shift 2
      ;;
    --max-samples=*)
      MAX_SAMPLES="${1#*=}"
      shift
      ;;
    --max-samples)
      [[ $# -ge 2 ]] || { echo "[ERROR] --max-samples needs a value" >&2; exit 2; }
      MAX_SAMPLES="$2"
      shift 2
      ;;
    --data-file=*)
      DATA_FILE="${1#*=}"
      DATA_MODE="single"
      DATA_FROM_CLI=1
      shift
      ;;
    --data-file)
      [[ $# -ge 2 ]] || { echo "[ERROR] --data-file needs a value" >&2; exit 2; }
      DATA_FILE="$2"
      DATA_MODE="single"
      DATA_FROM_CLI=1
      shift 2
      ;;
    --data-mode=*)
      DATA_MODE="${1#*=}"
      DATA_FROM_CLI=1
      shift
      ;;
    --data-mode)
      [[ $# -ge 2 ]] || { echo "[ERROR] --data-mode needs a value (all|single)" >&2; exit 2; }
      DATA_MODE="$2"
      DATA_FROM_CLI=1
      shift 2
      ;;
    --gcs-prefix=*)
      GCS_PREFIX="${1#*=}"
      GCS_FROM_CLI=1
      shift
      ;;
    --gcs-prefix)
      [[ $# -ge 2 ]] || { echo "[ERROR] --gcs-prefix needs a value" >&2; exit 2; }
      GCS_PREFIX="$2"
      GCS_FROM_CLI=1
      shift 2
      ;;
    --force-torch-reinstall)
      FORCE_TORCH_REINSTALL=1
      shift
      ;;
    --lora-target=*)
      LORA_TARGET="${1#*=}"
      shift
      ;;
    --lora-target)
      [[ $# -ge 2 ]] || { echo "[ERROR] --lora-target needs a value" >&2; exit 2; }
      LORA_TARGET="$2"
      shift 2
      ;;
    --lora-r=*)
      LORA_R="${1#*=}"
      LORA_R_SET=1
      shift
      ;;
    --lora-r)
      [[ $# -ge 2 ]] || { echo "[ERROR] --lora-r needs a value" >&2; exit 2; }
      LORA_R="$2"
      LORA_R_SET=1
      shift 2
      ;;
    --lora-alpha=*)
      LORA_ALPHA="${1#*=}"
      LORA_ALPHA_SET=1
      shift
      ;;
    --lora-alpha)
      [[ $# -ge 2 ]] || { echo "[ERROR] --lora-alpha needs a value" >&2; exit 2; }
      LORA_ALPHA="$2"
      LORA_ALPHA_SET=1
      shift 2
      ;;
    --skip-precheck)
      SKIP_PRECHECK=1
      shift
      ;;
    --resume=*)
      RESUME_MODE="${1#*=}"
      shift
      ;;
    --resume)
      [[ $# -ge 2 ]] || { echo "[ERROR] --resume needs a value (auto|never|path)" >&2; exit 2; }
      RESUME_MODE="$2"
      shift 2
      ;;
    --sync-every-steps=*)
      SYNC_EVERY_STEPS="${1#*=}"
      shift
      ;;
    --sync-every-steps)
      [[ $# -ge 2 ]] || { echo "[ERROR] --sync-every-steps needs a value (steps)" >&2; exit 2; }
      SYNC_EVERY_STEPS="$2"
      shift 2
      ;;
    --no-auto-sync)
      AUTO_SYNC_GCS=0
      shift
      ;;
    --yes|--auto-confirm)
      AUTO_CONFIRM=1
      shift
      ;;
    --interactive)
      INTERACTIVE_MODE=1
      INTERACTIVE_MODE_SET=1
      shift
      ;;
    --no-interactive)
      INTERACTIVE_MODE=0
      INTERACTIVE_MODE_SET=1
      shift
      ;;
    --prepare-deps=*)
      PREPARE_DEPS_MODE="${1#*=}"
      shift
      ;;
    --prepare-deps)
      [[ $# -ge 2 ]] || { echo "[ERROR] --prepare-deps needs a value (auto|always|never)" >&2; exit 2; }
      PREPARE_DEPS_MODE="$2"
      shift 2
      ;;
    --val-size=*)
      VAL_SIZE="${1#*=}"
      shift
      ;;
    --val-size)
      [[ $# -ge 2 ]] || { echo "[ERROR] --val-size needs a value" >&2; exit 2; }
      VAL_SIZE="$2"
      shift 2
      ;;
    --seed=*)
      SEED="${1#*=}"
      shift
      ;;
    --seed)
      [[ $# -ge 2 ]] || { echo "[ERROR] --seed needs a value" >&2; exit 2; }
      SEED="$2"
      shift 2
      ;;
    --cutoff-len=*)
      CUTOFF_LEN="${1#*=}"
      CUTOFF_LEN_SET=1
      shift
      ;;
    --cutoff-len)
      [[ $# -ge 2 ]] || { echo "[ERROR] --cutoff-len needs a value" >&2; exit 2; }
      CUTOFF_LEN="$2"
      CUTOFF_LEN_SET=1
      shift 2
      ;;
    --learning-rate=*)
      LEARNING_RATE="${1#*=}"
      LEARNING_RATE_SET=1
      shift
      ;;
    --learning-rate)
      [[ $# -ge 2 ]] || { echo "[ERROR] --learning-rate needs a value" >&2; exit 2; }
      LEARNING_RATE="$2"
      LEARNING_RATE_SET=1
      shift 2
      ;;
    --batch=*)
      BATCH_SIZE_OVERRIDE="${1#*=}"
      shift
      ;;
    --batch)
      [[ $# -ge 2 ]] || { echo "[ERROR] --batch needs a value" >&2; exit 2; }
      BATCH_SIZE_OVERRIDE="$2"
      shift 2
      ;;
    --grad-acc=*)
      GRAD_ACC_OVERRIDE="${1#*=}"
      shift
      ;;
    --grad-acc)
      [[ $# -ge 2 ]] || { echo "[ERROR] --grad-acc needs a value" >&2; exit 2; }
      GRAD_ACC_OVERRIDE="$2"
      shift 2
      ;;
    --save-steps=*)
      SAVE_STEPS_OVERRIDE="${1#*=}"
      shift
      ;;
    --save-steps)
      [[ $# -ge 2 ]] || { echo "[ERROR] --save-steps needs a value" >&2; exit 2; }
      SAVE_STEPS_OVERRIDE="$2"
      shift 2
      ;;
    --eval-steps=*)
      EVAL_STEPS="${1#*=}"
      shift
      ;;
    --eval-steps)
      [[ $# -ge 2 ]] || { echo "[ERROR] --eval-steps needs a value" >&2; exit 2; }
      EVAL_STEPS="$2"
      shift 2
      ;;
    --shuffle-data)
      SHUFFLE_DATA=1
      shift
      ;;
    --no-shuffle-data)
      SHUFFLE_DATA=0
      shift
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "[WARN] unknown arg: $1"
      shift
      ;;
  esac
done

WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "${POOPTRAIN_WORKSPACE_DIR:-$WORK_DIR}" "$DEFAULT_WORKSPACE_DIR")"
VENV_DIR="$WORK_DIR/venv"
LLF_DIR="$WORK_DIR/LLaMA-Factory"
CONFIG_DIR="$WORK_DIR/configs"
OUT_DIR="$WORK_DIR/output_poop_sft"
RUN_META_FILE="$WORK_DIR/last_run.env"
RUNS_DIR="$WORK_DIR/runs"
TMP_WORK_DIR="$WORK_DIR/tmp"
HF_HOME_DIR="$WORK_DIR/hf_home"
PIP_CACHE_DIR="$WORK_DIR/pip_cache"
XDG_CACHE_DIR="$WORK_DIR/.cache"
TORCH_HOME_DIR="$WORK_DIR/torch_home"
BASE_MODELS_DIR="$WORK_DIR/base_models"

has_nvidia_pci() {
  if ! check_cmd lspci; then
    return 1
  fi
  lspci | grep -Eiq 'nvidia|3d controller.*nvidia|vga compatible controller.*nvidia'
}
python_deps_ready() {
  [[ -x "$VENV_DIR/bin/python" ]] || return 1
  [[ -d "$LLF_DIR" ]] || return 1
  "$VENV_DIR/bin/python" - <<'PY' >/dev/null 2>&1
import torch
import transformers
import peft
import datasets
import accelerate
import trl
import gradio
import huggingface_hub
import llamafactory
print("ok")
PY
}

mkdir -p "$WORK_DIR" "$CONFIG_DIR" "$BASE_MODELS_DIR" "$RUNS_DIR"

mkdir -p "$TMP_WORK_DIR" "$HF_HOME_DIR" "$PIP_CACHE_DIR" "$XDG_CACHE_DIR" "$TORCH_HOME_DIR"
export TMPDIR="$TMP_WORK_DIR"
export TMP="$TMP_WORK_DIR"
export TEMP="$TMP_WORK_DIR"
export HF_HOME="$HF_HOME_DIR"
export HUGGINGFACE_HUB_CACHE="$HF_HOME_DIR/hub"
export TRANSFORMERS_CACHE="$HF_HOME_DIR/transformers"
export TORCH_HOME="$TORCH_HOME_DIR"
export XDG_CACHE_HOME="$XDG_CACHE_DIR"
export PIP_CACHE_DIR="$PIP_CACHE_DIR"
export PIP_NO_CACHE_DIR=1

# Load workspace-level defaults when CLI did not pin them.
if [[ "$GCS_FROM_CLI" -eq 0 ]]; then
  WORKSPACE_CFG_FILE="$WORK_DIR/train_config.env"
  if [[ -f "$WORKSPACE_CFG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$WORKSPACE_CFG_FILE" >/dev/null 2>&1 || true
    if [[ -n "${POOPTRAIN_GCS_PREFIX:-}" ]]; then
      GCS_PREFIX="$POOPTRAIN_GCS_PREFIX"
    fi
  fi
  if [[ -z "${GCS_PREFIX:-}" && -f "$WORK_DIR/last_run.env" ]]; then
    # shellcheck disable=SC1090
    source "$WORK_DIR/last_run.env" >/dev/null 2>&1 || true
    if [[ -n "${LAST_GCS_PREFIX:-}" ]]; then
      GCS_PREFIX="$LAST_GCS_PREFIX"
    fi
  fi
fi

echo "[INFO] storage routing:"
echo "  TMPDIR=$TMPDIR"
echo "  HF_HOME=$HF_HOME"
echo "  PIP_CACHE_DIR=$PIP_CACHE_DIR"
echo "  project_fs_free=$(df -h "$BASE_DIR" | awk 'NR==2 {print $4}')"
echo "  tmp_fs_free=$(df -h /tmp | awk 'NR==2 {print $4}')"

# Hardware summary before any heavy install/download.
HAS_GPU=0
if check_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
  HAS_GPU=1
fi
HAS_NVIDIA_PCI=0
if has_nvidia_pci; then
  HAS_NVIDIA_PCI=1
fi
if [[ "$HAS_GPU" -eq 1 ]]; then
  HW_SUMMARY="GPU"
elif [[ "$HAS_NVIDIA_PCI" -eq 1 ]]; then
  HW_SUMMARY="NVIDIA PCI detected, driver not ready"
else
  HW_SUMMARY="CPU-only"
fi

if is_tty && [[ "$INTERACTIVE_MODE_SET" -eq 0 ]]; then
  INTERACTIVE_MODE=1
fi

if [[ "$INTERACTIVE_MODE" -eq 1 ]] && is_tty; then
  echo "[INFO] interactive setup:"
  if [[ "$WORKSPACE_FROM_CLI" -eq 0 ]]; then
    pt_read_prompt WS_INPUT "Workspace name/path [default=${DEFAULT_WORKSPACE_NAME}] (press Enter to use ${DEFAULT_WORKSPACE_NAME} by default): "
    WS_INPUT="${WS_INPUT:-$DEFAULT_WORKSPACE_NAME}"
    WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WS_INPUT" "$DEFAULT_WORKSPACE_DIR")"
    VENV_DIR="$WORK_DIR/venv"
    LLF_DIR="$WORK_DIR/LLaMA-Factory"
    CONFIG_DIR="$WORK_DIR/configs"
    OUT_DIR="$WORK_DIR/output_poop_sft"
    RUN_META_FILE="$WORK_DIR/last_run.env"
    RUNS_DIR="$WORK_DIR/runs"
    TMP_WORK_DIR="$WORK_DIR/tmp"
    HF_HOME_DIR="$WORK_DIR/hf_home"
    PIP_CACHE_DIR="$WORK_DIR/pip_cache"
    XDG_CACHE_DIR="$WORK_DIR/.cache"
    TORCH_HOME_DIR="$WORK_DIR/torch_home"
    BASE_MODELS_DIR="$WORK_DIR/base_models"
    echo "[INFO] workspace_dir=$WORK_DIR"
    if [[ "$GCS_FROM_CLI" -eq 0 ]]; then
      WORKSPACE_CFG_FILE="$WORK_DIR/train_config.env"
      if [[ -f "$WORKSPACE_CFG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$WORKSPACE_CFG_FILE" >/dev/null 2>&1 || true
        if [[ -n "${POOPTRAIN_GCS_PREFIX:-}" ]]; then
          GCS_PREFIX="$POOPTRAIN_GCS_PREFIX"
        fi
      elif [[ -f "$WORK_DIR/last_run.env" ]]; then
        # shellcheck disable=SC1090
        source "$WORK_DIR/last_run.env" >/dev/null 2>&1 || true
        if [[ -n "${LAST_GCS_PREFIX:-}" ]]; then
          GCS_PREFIX="$LAST_GCS_PREFIX"
        fi
      fi
    fi
  fi
  mkdir -p "$WORK_DIR" "$CONFIG_DIR" "$TMP_WORK_DIR" "$HF_HOME_DIR" "$PIP_CACHE_DIR" "$XDG_CACHE_DIR" "$TORCH_HOME_DIR" "$BASE_MODELS_DIR" "$RUNS_DIR"
  export TMPDIR="$TMP_WORK_DIR"
  export TMP="$TMP_WORK_DIR"
  export TEMP="$TMP_WORK_DIR"
  export HF_HOME="$HF_HOME_DIR"
  export HUGGINGFACE_HUB_CACHE="$HF_HOME_DIR/hub"
  export TRANSFORMERS_CACHE="$HF_HOME_DIR/transformers"
  export TORCH_HOME="$TORCH_HOME_DIR"
  export XDG_CACHE_HOME="$XDG_CACHE_DIR"
  export PIP_CACHE_DIR="$PIP_CACHE_DIR"
  export PIP_NO_CACHE_DIR=1
  echo "[INFO] storage routing (workspace override):"
  echo "  TMPDIR=$TMPDIR"
  echo "  HF_HOME=$HF_HOME"
  echo "  PIP_CACHE_DIR=$PIP_CACHE_DIR"
  echo "  workspace_fs_free=$(df -h "$WORK_DIR" | awk 'NR==2 {print $4}')"
  pt_read_prompt GCS_INPUT "Use GCS sync prefix [input gs://bucketName/exports/<run-name> (e.g. gs://my-bucket/exports/test) to enable; default=${GCS_PREFIX:-blank/skip}; off/none/0=disable] (press Enter to keep current by default): "
  if [[ -n "${GCS_INPUT:-}" ]]; then
    GCS_INPUT_LC="$(echo "$GCS_INPUT" | tr '[:upper:]' '[:lower:]')"
    if [[ "$GCS_INPUT_LC" == "0" || "$GCS_INPUT_LC" == "off" || "$GCS_INPUT_LC" == "disable" || "$GCS_INPUT_LC" == "none" ]]; then
      GCS_PREFIX=""
      AUTO_SYNC_GCS=0
    else
      GCS_PREFIX="$GCS_INPUT"
    fi
  fi
fi

pt_persist_workspace_choice "$WORK_DIR" "$GLOBAL_CFG_DIR" "$GLOBAL_CFG_FILE"
if [[ "$GCS_FROM_CLI" -eq 0 ]]; then
  WORKSPACE_CFG_FILE="$WORK_DIR/train_config.env"
  mkdir -p "$(dirname "$WORKSPACE_CFG_FILE")"
  touch "$WORKSPACE_CFG_FILE"
  if grep -q '^POOPTRAIN_GCS_PREFIX=' "$WORKSPACE_CFG_FILE"; then
    sed -i "s|^POOPTRAIN_GCS_PREFIX=.*|POOPTRAIN_GCS_PREFIX=${GCS_PREFIX}|" "$WORKSPACE_CFG_FILE"
  else
    printf 'POOPTRAIN_GCS_PREFIX=%s\n' "$GCS_PREFIX" >> "$WORKSPACE_CFG_FILE"
  fi
fi

if [[ "$SKIP_PRECHECK" -ne 1 ]]; then
  PRECHECK_ARGS=(--workspace-dir "$WORK_DIR")
  if [[ -n "$GCS_PREFIX" ]]; then
    PRECHECK_ARGS+=(--gcs-prefix "$GCS_PREFIX")
  fi
  # Single precheck pass: environment + optional dependency prepare.
  case "$PREPARE_DEPS_MODE" in
    auto)
      if python_deps_ready; then
        echo "[INFO] python deps already ready, skip dependency install"
      else
        PRECHECK_ARGS+=(--prepare-python)
      fi
      ;;
    always)
      PRECHECK_ARGS+=(--prepare-python --prepare-python-force)
      ;;
    never)
      ;;
    *)
      echo "[ERROR] invalid --prepare-deps: $PREPARE_DEPS_MODE (use auto|always|never)" >&2
      exit 2
      ;;
  esac
  bash "$BASE_DIR/scripts/precheck_env.sh" "${PRECHECK_ARGS[@]}"
fi

if [[ "$MODEL_FROM_CLI" -eq 0 ]] && is_tty; then
  while true; do
    echo "[INFO] training mode:"
    echo "  1) train new model (default)"
    echo "  2) continue existing training"
    while true; do
      pt_read_prompt TRAIN_MODE_CHOICE "Choose mode [1/2, default=1] (press Enter to use option 1 by default): "
      TRAIN_MODE_CHOICE="${TRAIN_MODE_CHOICE:-1}"
      if [[ "$TRAIN_MODE_CHOICE" == "1" || "$TRAIN_MODE_CHOICE" == "2" ]]; then
        break
      fi
      echo "[WARN] invalid mode: $TRAIN_MODE_CHOICE"
    done

    if [[ "$TRAIN_MODE_CHOICE" == "2" ]]; then
      RESUME_MODE="auto"
      mapfile -t RESUME_CANDIDATES < <(find "$WORK_DIR" -type d -name 'checkpoint-*' | sort -V)
      if [[ "${#RESUME_CANDIDATES[@]}" -gt 0 ]]; then
        echo "[INFO] found checkpoint candidates:"
        idx=1
        for c in "${RESUME_CANDIDATES[@]}"; do
          echo "  [$idx] $c"
          idx=$((idx + 1))
        done
        echo "  [m] manual path"
        echo "  [b] back"
        while true; do
          pt_read_prompt CKPT_CHOICE "Choose checkpoint [default=latest, b=back] (press Enter to use latest by default): "
          if [[ -z "${CKPT_CHOICE:-}" ]]; then
            RESUME_MODE="${RESUME_CANDIDATES[$((${#RESUME_CANDIDATES[@]} - 1))]}"
            break
          elif [[ "$CKPT_CHOICE" == "b" || "$CKPT_CHOICE" == "B" ]]; then
            continue 2
          elif [[ "$CKPT_CHOICE" == "m" || "$CKPT_CHOICE" == "M" ]]; then
            pt_read_prompt CKPT_PATH "Enter checkpoint path [b=back]: "
            if [[ "$CKPT_PATH" == "b" || "$CKPT_PATH" == "B" ]]; then
              continue
            fi
            if [[ -z "${CKPT_PATH:-}" ]]; then
              echo "[WARN] empty checkpoint path, please retry"
              continue
            fi
            if [[ "$CKPT_PATH" != /* ]]; then CKPT_PATH="$BASE_DIR/$CKPT_PATH"; fi
            if [[ ! -d "$CKPT_PATH" ]]; then
              echo "[WARN] checkpoint path not found: $CKPT_PATH"
              continue
            fi
            RESUME_MODE="$CKPT_PATH"
            break
          elif [[ "$CKPT_CHOICE" =~ ^[0-9]+$ ]] && (( CKPT_CHOICE >= 1 && CKPT_CHOICE <= ${#RESUME_CANDIDATES[@]} )); then
            RESUME_MODE="${RESUME_CANDIDATES[$((CKPT_CHOICE - 1))]}"
            break
          else
            echo "[WARN] invalid checkpoint selection: $CKPT_CHOICE"
          fi
        done
      else
        echo "[WARN] no local checkpoint found under $WORK_DIR"
        echo "  1) back to mode menu"
        echo "  2) switch to train-new"
        pt_read_prompt NOCKPT_CHOICE "Choose [1/2, default=2] (press Enter to use option 2 by default): "
        NOCKPT_CHOICE="${NOCKPT_CHOICE:-2}"
        if [[ "$NOCKPT_CHOICE" == "1" ]]; then
          continue
        fi
        RESUME_MODE="never"
        TRAIN_MODE_CHOICE="1"
      fi
    else
      RESUME_MODE="never"
    fi

    while true; do
      echo "[INFO] base model source:"
      echo "  1) use local downloaded base model"
      echo "  2) choose/download base model id"
      echo "  b) back"
      while true; do
        pt_read_prompt MODEL_SOURCE_CHOICE "Choose source [1/2, b=back, default=2] (press Enter to use option 2 by default): "
        MODEL_SOURCE_CHOICE="${MODEL_SOURCE_CHOICE:-2}"
        if [[ "$MODEL_SOURCE_CHOICE" == "1" || "$MODEL_SOURCE_CHOICE" == "2" || "$MODEL_SOURCE_CHOICE" == "b" || "$MODEL_SOURCE_CHOICE" == "B" ]]; then
          break
        fi
        echo "[WARN] invalid source selection: $MODEL_SOURCE_CHOICE"
      done

      if [[ "$MODEL_SOURCE_CHOICE" == "b" || "$MODEL_SOURCE_CHOICE" == "B" ]]; then
        break
      fi

      if [[ "$MODEL_SOURCE_CHOICE" == "1" ]]; then
        mapfile -t LOCAL_BASE_MODELS < <(find "$BASE_MODELS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
        if [[ "${#LOCAL_BASE_MODELS[@]}" -eq 0 ]]; then
          echo "[WARN] no local base models found under: $BASE_MODELS_DIR"
          continue
        fi
        echo "[INFO] local base models:"
        idx=1
        for m in "${LOCAL_BASE_MODELS[@]}"; do
          echo "  [$idx] $m"
          idx=$((idx + 1))
        done
        echo "  [b] back"
        while true; do
          pt_read_prompt LOCAL_MODEL_PICK "Select local model [1-${#LOCAL_BASE_MODELS[@]}, b=back, default=1] (press Enter to use default by default): "
          LOCAL_MODEL_PICK="${LOCAL_MODEL_PICK:-1}"
          if [[ "$LOCAL_MODEL_PICK" == "b" || "$LOCAL_MODEL_PICK" == "B" ]]; then
            break
          fi
          if [[ "$LOCAL_MODEL_PICK" =~ ^[0-9]+$ ]] && (( LOCAL_MODEL_PICK >= 1 && LOCAL_MODEL_PICK <= ${#LOCAL_BASE_MODELS[@]} )); then
            MODEL_NAME="${LOCAL_BASE_MODELS[$((LOCAL_MODEL_PICK - 1))]}"
            break 2
          fi
          echo "[WARN] invalid local model selection: $LOCAL_MODEL_PICK"
        done
        continue
      fi

      echo "[INFO] base model selection:"
      MODEL_PICKED="$(pick_model_id_interactive "$MODEL_NAME")"
      if [[ "$MODEL_PICKED" == "__BACK__" ]]; then
        continue
      fi
      [[ -n "$MODEL_PICKED" ]] || { echo "[WARN] empty model id, retry"; continue; }
      MODEL_NAME="$MODEL_PICKED"
      break 2
    done
  done
fi

if [[ "$DATA_FROM_CLI" -eq 0 ]] && is_tty; then
  while true; do
    build_data_selection_interactive
    data_rc=$?
    if [[ "$data_rc" -eq 0 ]]; then
      break
    fi
    if [[ "$data_rc" -eq 10 ]]; then
      echo "[INFO] already at top level for dataset selection; staying on this step."
      continue
    fi
    echo "[ERROR] dataset selection failed, retrying..."
  done
fi

if [[ "$RUN_NAME_FROM_CLI" -eq 0 ]] && [[ "$RESUME_MODE" == "never" ]] && is_tty; then
  model_tag="$(basename "$MODEL_NAME" | tr '/: ' '___' | tr -cd 'A-Za-z0-9._-')"
  [[ -n "$model_tag" ]] || model_tag="run"
  default_run_name="${model_tag}_$(date +%Y%m%d_%H%M%S)"
  pt_read_prompt RUN_NAME_INPUT "Run name [default=${default_run_name}] (press Enter to use default by default): "
  RUN_NAME="${RUN_NAME_INPUT:-$default_run_name}"
fi

if [[ -z "$RUN_NAME" ]] && [[ "$RESUME_MODE" == "never" ]]; then
  model_tag="$(basename "$MODEL_NAME" | tr '/: ' '___' | tr -cd 'A-Za-z0-9._-')"
  [[ -n "$model_tag" ]] || model_tag="run"
  RUN_NAME="${model_tag}_$(date +%Y%m%d_%H%M%S)"
fi

if [[ "$RESUME_MODE" == "auto" && -f "$RUN_META_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$RUN_META_FILE" >/dev/null 2>&1 || true
  if [[ -n "${LAST_OUTPUT_DIR:-}" && -d "${LAST_OUTPUT_DIR:-}" ]]; then
    OUT_DIR="$LAST_OUTPUT_DIR"
    RUN_DIR="$(dirname "$OUT_DIR")"
    RUN_NAME="$(basename "$RUN_DIR")"
  fi
fi

if [[ "$RESUME_MODE" != "never" && "$RESUME_MODE" != "auto" ]]; then
  OUT_DIR="$(dirname "$RESUME_MODE")"
  RUN_DIR="$(dirname "$OUT_DIR")"
  RUN_NAME="$(basename "$RUN_DIR")"
else
  if [[ -z "$RUN_DIR" ]]; then
    RUN_DIR="$RUNS_DIR/$RUN_NAME"
  fi
  OUT_DIR="$RUN_DIR/output_poop_sft"
fi
CONFIG_DIR="$RUN_DIR/configs"
RUN_META_DETAIL_FILE="$RUN_DIR/run.env"
mkdir -p "$RUN_DIR" "$CONFIG_DIR" "$OUT_DIR"

if is_tty; then
  pt_read_prompt SHUF_INPUT "Shuffle merged dataset entries before train? [Y/n] (press Enter to enable shuffle by default): "
  case "${SHUF_INPUT:-Y}" in
    y|Y|yes|YES|"") SHUFFLE_DATA=1 ;;
    *) SHUFFLE_DATA=0 ;;
  esac
fi

echo "[INFO] plan summary before dependency prepare:"
echo "  run_name=$RUN_NAME"
echo "  run_dir=$RUN_DIR"
echo "  model=$MODEL_NAME"
echo "  resume_mode=$RESUME_MODE"
echo "  data_mode=$DATA_MODE"
echo "  data_input=$DATA_FILE"
echo "  shuffle_data=$SHUFFLE_DATA"
if [[ -n "$GCS_PREFIX" ]]; then
  echo "  gcs_prefix=$GCS_PREFIX"
else
  echo "  gcs_prefix=(disabled)"
fi

if [[ "$AUTO_CONFIRM" -ne 1 ]] && is_tty; then
  echo "[INFO] detected hardware: $HW_SUMMARY"
  echo "[INFO] workspace dir: $WORK_DIR"
  if [[ -n "$GCS_PREFIX" ]]; then
    echo "[INFO] GCS auto-sync: enabled (step-based, target=$GCS_PREFIX)"
  else
    echo "[INFO] GCS auto-sync: disabled"
  fi
  pt_read_prompt PROCEED "Proceed with this plan? [Y/n] (press Enter to continue by default): "
  case "${PROCEED:-Y}" in
    y|Y|yes|YES|"") ;;
    *) echo "[INFO] cancelled by user before training start"; exit 0 ;;
  esac
fi

if [[ "$DATA_MODE" != "all" && "$DATA_MODE" != "single" && "$DATA_MODE" != "selected" ]]; then
  echo "[ERROR] unsupported --data-mode: $DATA_MODE (use all|single|selected)" >&2
  exit 2
fi

MERGED_DATA_FILE="$RUN_DIR/merged_dataset.jsonl"
mapfile -t DATA_FILES < <(pt_collect_data_files "$DATA_MODE" "$DATA_FILE" "$BASE_DIR")
if [[ "$DATA_MODE" == "all" || "$DATA_MODE" == "selected" ]]; then
  pt_merge_jsonl_files "$MERGED_DATA_FILE" "${DATA_FILES[@]}"
  DATA_FILE="$MERGED_DATA_FILE"
  echo "[INFO] data_mode=${DATA_MODE}, merged_files=${#DATA_FILES[@]}"
  printf '  - %s\n' "${DATA_FILES[@]}"
  echo "[INFO] merged_data_file=$DATA_FILE"
else
  DATA_FILE="${DATA_FILES[0]}"
  [[ -f "$DATA_FILE" ]] || { echo "[ERROR] data file not found: $DATA_FILE" >&2; exit 2; }
  echo "[INFO] data_mode=single"
  echo "[INFO] data_file=$DATA_FILE"
fi

NORMALIZED_DATA_FILE="$RUN_DIR/normalized_dataset.jsonl"
mapfile -t NORMALIZE_LINES < <(pt_normalize_jsonl_file "$DATA_FILE" "$NORMALIZED_DATA_FILE" "$PYTHON_SYS_BIN")
for line in "${NORMALIZE_LINES[@]}"; do
  case "$line" in
    normalized_rows=*) NORMALIZED_ROWS="${line#normalized_rows=}" ;;
    normalized_skipped=*) NORMALIZED_SKIPPED="${line#normalized_skipped=}" ;;
  esac
done
DATA_FILE="$NORMALIZED_DATA_FILE"
echo "[INFO] normalized_data_file=$DATA_FILE rows=${NORMALIZED_ROWS:-0} skipped=${NORMALIZED_SKIPPED:-0}"

if [[ "$SHUFFLE_DATA" == "1" ]]; then
  SHUFFLED_DATA_FILE="$RUN_DIR/shuffled_dataset.jsonl"
  pt_shuffle_jsonl_file "$DATA_FILE" "$SHUFFLED_DATA_FILE" "$SEED" "$PYTHON_SYS_BIN"
  DATA_FILE="$SHUFFLED_DATA_FILE"
  echo "[INFO] shuffle_data=on seed=$SEED"
  echo "[INFO] shuffled_data_file=$DATA_FILE"
else
  echo "[INFO] shuffle_data=off"
fi

DATASET_ROWS="$(pt_count_nonempty_rows "$DATA_FILE")"
mapfile -t DATA_STATS < <(pt_compute_dataset_stats "$DATA_FILE" "$PYTHON_SYS_BIN")
for line in "${DATA_STATS[@]}"; do
  case "$line" in
    rows=*) DATA_STATS_ROWS="${line#rows=}" ;;
    json_errors=*) DATA_JSON_ERRORS="${line#json_errors=}" ;;
    avg_chars=*) DATA_AVG_CHARS="${line#avg_chars=}" ;;
    p95_chars=*) DATA_P95_CHARS="${line#p95_chars=}" ;;
    max_chars=*) DATA_MAX_CHARS="${line#max_chars=}" ;;
  esac
done
echo "[INFO] dataset stats: rows=${DATA_STATS_ROWS:-$DATASET_ROWS}, json_errors=${DATA_JSON_ERRORS:-0}, avg_chars=${DATA_AVG_CHARS:-0}, p95_chars=${DATA_P95_CHARS:-0}, max_chars=${DATA_MAX_CHARS:-0}"

[[ -d "$VENV_DIR" ]] || { echo "[ERROR] venv missing: $VENV_DIR (run precheck with --prepare-python)" >&2; exit 2; }
[[ -d "$LLF_DIR" ]] || { echo "[ERROR] LLaMA-Factory missing: $LLF_DIR (run precheck with --prepare-python)" >&2; exit 2; }
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
cd "$LLF_DIR"

# Hard check: torch must exist first.
if ! python - <<'PY' >/dev/null 2>&1
import torch
print(torch.__version__)
PY
then
  echo "[ERROR] torch not found in venv. run precheck (without --skip-precheck) to prepare python deps." >&2
  exit 2
fi

# Optional forced reinstall by user.
if [[ "$FORCE_TORCH_REINSTALL" -eq 1 ]]; then
  echo "[INFO] force reinstall torch requested"
  python -m pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true
  if [[ "$HAS_GPU" -eq 1 ]]; then
    python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio
  else
    python -m pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision torchaudio
  fi
fi

CUDA_AVAILABLE="$(python - <<'PY'
import torch
print("1" if torch.cuda.is_available() else "0")
PY
)"

# Hard guard for GPU nodes: if GPU exists but torch cuda is unavailable, auto-fix once.
if [[ "$HAS_GPU" -eq 1 ]] && [[ "$CUDA_AVAILABLE" != "1" ]]; then
  echo "[WARN] GPU detected but torch cuda_available=False; trying auto-fix CUDA torch..."
  python -m pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true
  python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio
  CUDA_AVAILABLE="$(python - <<'PY'
import torch
print("1" if torch.cuda.is_available() else "0")
PY
)"
fi

if [[ "$HAS_GPU" -eq 1 ]] && [[ "$CUDA_AVAILABLE" != "1" ]]; then
  echo "[ERROR] GPU detected but torch cuda is still unavailable." >&2
  echo "[ERROR] Re-run with: ./scripts/run_train_job.sh --prepare-deps always --force-torch-reinstall" >&2
  exit 2
fi
if [[ "$HAS_GPU" -eq 0 ]] && [[ "$HAS_NVIDIA_PCI" -eq 1 ]]; then
  echo "[ERROR] NVIDIA GPU hardware detected but driver/CUDA is still not ready (nvidia-smi unavailable)." >&2
  echo "[ERROR] install driver and reboot first, then rerun training." >&2
  exit 2
fi

python - <<'PY'
import torch
print(f"[INFO] torch={torch.__version__}, cuda_available={torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"[INFO] gpu_count={torch.cuda.device_count()}, bf16_supported={torch.cuda.is_bf16_supported()}")
PY

# Pull model files first (fast fail if auth/network issue).
# For HF model ids, always store/reuse under workspace/base_models.
if [[ -d "$MODEL_NAME" ]]; then
  [[ -f "$MODEL_NAME/config.json" ]] || { echo "[ERROR] local model dir missing config.json: $MODEL_NAME" >&2; exit 2; }
  echo "[INFO] using local base model dir: $MODEL_NAME"
else
  MODEL_ID="$MODEL_NAME"
  SAFE_MODEL_DIR="$(echo "$MODEL_ID" | tr '/:' '__' | tr -cd 'A-Za-z0-9._-')"
  [[ -n "$SAFE_MODEL_DIR" ]] || SAFE_MODEL_DIR="model"
  TARGET_MODEL_DIR="$BASE_MODELS_DIR/$SAFE_MODEL_DIR"
  mkdir -p "$TARGET_MODEL_DIR"
  if [[ -f "$TARGET_MODEL_DIR/config.json" ]]; then
    echo "[INFO] found local base model cache: $TARGET_MODEL_DIR"
  else
    echo "[INFO] local base model cache not found, downloading: $MODEL_ID"
  fi
  python - <<PY
from huggingface_hub import snapshot_download
print('downloading model:', '$MODEL_ID')
snapshot_download(repo_id='$MODEL_ID', local_dir='$TARGET_MODEL_DIR')
print('model download check done')
PY
  MODEL_NAME="$TARGET_MODEL_DIR"
  echo "[INFO] using local base model dir: $MODEL_NAME"
fi

# dataset_info
LLF_DIR_ENV="$LLF_DIR" DATA_FILE_ENV="$DATA_FILE" python - <<'PY'
import json
from pathlib import Path
import os
llf = Path(os.environ['LLF_DIR_ENV'])
info_file = llf / 'data' / 'dataset_info.json'
entry_name = 'poop_sft_zh'
entry = {
    'file_name': os.environ['DATA_FILE_ENV'],
    'formatting': 'alpaca',
    'columns': {'prompt':'instruction','query':'input','response':'output'}
}
obj = {}
if info_file.exists():
    try: obj = json.loads(info_file.read_text(encoding='utf-8'))
    except Exception: obj = {}
obj[entry_name] = entry
info_file.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding='utf-8')
print(info_file)
PY

CPU_CORES="$(getconf _NPROCESSORS_ONLN || echo 1)"

model_lc="$(echo "$MODEL_NAME" | tr '[:upper:]' '[:lower:]')"
if [[ "$TEMPLATE_NAME" == "auto" ]]; then
  if [[ "$model_lc" == *"qwen3"* ]] || [[ "$model_lc" == *"qwen2.5"* ]] || [[ "$model_lc" == *"qwen2"* ]] || [[ "$model_lc" == *"qwen"* ]]; then
    TEMPLATE_NAME="qwen"
  elif [[ "$model_lc" == *"llama"* ]] || [[ "$model_lc" == *"mistral"* ]]; then
    TEMPLATE_NAME="llama3"
  else
    TEMPLATE_NAME="default"
  fi
  echo "[INFO] auto template: $TEMPLATE_NAME"
fi

if [[ "$LORA_TARGET" == "all" ]]; then
  if [[ "$model_lc" == *"qwen3"* ]] || [[ "$model_lc" == *"qwen2.5"* ]] || [[ "$model_lc" == *"qwen2"* ]] || [[ "$model_lc" == *"qwen"* ]]; then
    LORA_TARGET="q_proj,k_proj,v_proj,o_proj,up_proj,down_proj,gate_proj"
    echo "[INFO] auto lora_target for Qwen-family: $LORA_TARGET"
  fi
fi

mapfile -t SUGGEST_LINES < <(pt_suggest_defaults "$MODEL_NAME" "${DATASET_ROWS:-0}" "$HAS_GPU")
for line in "${SUGGEST_LINES[@]}"; do
  case "$line" in
    DEF_EPOCHS=*) DEF_EPOCHS="${line#DEF_EPOCHS=}" ;;
    DEF_CUTOFF_LEN=*) DEF_CUTOFF_LEN="${line#DEF_CUTOFF_LEN=}" ;;
    DEF_BATCH=*) BATCH="${line#DEF_BATCH=}" ;;
    DEF_GRAD_ACC=*) GRAD_ACC="${line#DEF_GRAD_ACC=}" ;;
    DEF_LR=*) LR="${line#DEF_LR=}" ;;
    DEF_SAVE_STEPS=*) SAVE_STEPS="${line#DEF_SAVE_STEPS=}" ;;
    DEF_LORA_R=*) DEF_LORA_R="${line#DEF_LORA_R=}" ;;
    DEF_LORA_ALPHA=*) DEF_LORA_ALPHA="${line#DEF_LORA_ALPHA=}" ;;
  esac
done

if [[ "$CUTOFF_LEN_SET" -eq 0 ]]; then
  CUTOFF_LEN="$DEF_CUTOFF_LEN"
fi
if [[ -n "$BATCH_SIZE_OVERRIDE" ]]; then
  BATCH="$BATCH_SIZE_OVERRIDE"
fi
if [[ -n "$GRAD_ACC_OVERRIDE" ]]; then
  GRAD_ACC="$GRAD_ACC_OVERRIDE"
fi
if [[ "$LEARNING_RATE_SET" -eq 1 ]]; then
  LR="$LEARNING_RATE"
fi
if [[ -n "$SAVE_STEPS_OVERRIDE" ]]; then
  SAVE_STEPS="$SAVE_STEPS_OVERRIDE"
fi
if [[ -z "$EVAL_STEPS" ]]; then
  EVAL_STEPS="$SAVE_STEPS"
fi
if [[ -z "$SYNC_EVERY_STEPS" ]]; then
  SYNC_EVERY_STEPS="$SAVE_STEPS"
fi

if [[ "$LORA_R_SET" -eq 0 ]]; then
  LORA_R="$DEF_LORA_R"
fi
if [[ "$LORA_ALPHA_SET" -eq 0 ]]; then
  LORA_ALPHA="$DEF_LORA_ALPHA"
fi

if [[ "$INTERACTIVE_MODE" -eq 1 ]] && is_tty; then
  echo "[INFO] training parameter setup:"
  while true; do
    pt_read_prompt LORA_R_INPUT "LoRA rank r [default=$LORA_R] (press Enter to use default by default): "
    if [[ -z "${LORA_R_INPUT:-}" ]]; then
      break
    fi
    if [[ "$LORA_R_INPUT" =~ ^[0-9]+$ ]]; then
      LORA_R="$LORA_R_INPUT"
      LORA_R_SET=1
      break
    fi
    echo "[WARN] invalid LoRA rank, expect integer"
  done

  while true; do
    pt_read_prompt LORA_ALPHA_INPUT "LoRA alpha [default=$LORA_ALPHA] (press Enter to use default by default): "
    if [[ -z "${LORA_ALPHA_INPUT:-}" ]]; then
      break
    fi
    if [[ "$LORA_ALPHA_INPUT" =~ ^[0-9]+$ ]]; then
      LORA_ALPHA="$LORA_ALPHA_INPUT"
      LORA_ALPHA_SET=1
      break
    fi
    echo "[WARN] invalid LoRA alpha, expect integer"
  done

  while true; do
    pt_read_prompt LR_INPUT "Learning rate [default=$LR] (press Enter to use default by default): "
    if [[ -z "${LR_INPUT:-}" ]]; then
      break
    fi
    if [[ "$LR_INPUT" =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
      LR="$LR_INPUT"
      LEARNING_RATE_SET=1
      break
    fi
    echo "[WARN] invalid learning rate, expect float like 1e-4"
  done

  if [[ "$EPOCHS_SET" -eq 0 && "$MAX_STEPS_SET" -eq 0 ]]; then
    while true; do
      pt_read_prompt EP_INPUT "Num train epochs [default=$DEF_EPOCHS] (press Enter to use default by default): "
      if [[ -z "${EP_INPUT:-}" ]]; then
        break
      fi
      if [[ "$EP_INPUT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        NUM_TRAIN_EPOCHS="$EP_INPUT"
        EPOCHS_SET=1
        MAX_STEPS=""
        MAX_STEPS_SET=0
        break
      fi
      echo "[WARN] invalid epochs, expect number like 3 or 5"
    done
  fi
fi

SYNC_STEPS_LC="$(echo "${SYNC_EVERY_STEPS:-}" | tr '[:upper:]' '[:lower:]')"
if [[ "$SYNC_STEPS_LC" == "0" || "$SYNC_STEPS_LC" == "off" || "$SYNC_STEPS_LC" == "disable" || "$SYNC_STEPS_LC" == "none" ]]; then
  AUTO_SYNC_GCS=0
  SYNC_EVERY_STEPS=0
fi

if [[ "$MAX_STEPS_SET" -eq 1 ]] && [[ "$EPOCHS_SET" -eq 1 ]]; then
  echo "[ERROR] --max-steps and --num-train-epochs are mutually exclusive" >&2
  exit 2
fi

if [[ "$MAX_STEPS_SET" -eq 1 ]]; then
  [[ "$MAX_STEPS" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid --max-steps: $MAX_STEPS" >&2; exit 2; }
  NUM_TRAIN_EPOCHS="1.0"
elif [[ "$EPOCHS_SET" -eq 1 ]]; then
  [[ "$NUM_TRAIN_EPOCHS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "[ERROR] invalid --num-train-epochs: $NUM_TRAIN_EPOCHS" >&2; exit 2; }
  MAX_STEPS=""
else
  NUM_TRAIN_EPOCHS="$DEF_EPOCHS"
  MAX_STEPS=""
fi

[[ "$BATCH" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid batch size: $BATCH" >&2; exit 2; }
[[ "$GRAD_ACC" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid grad acc: $GRAD_ACC" >&2; exit 2; }
[[ "$SAVE_STEPS" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid save_steps: $SAVE_STEPS" >&2; exit 2; }
[[ "$EVAL_STEPS" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid eval_steps: $EVAL_STEPS" >&2; exit 2; }
[[ "$LORA_R" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid lora_r: $LORA_R" >&2; exit 2; }
[[ "$LORA_ALPHA" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid lora_alpha: $LORA_ALPHA" >&2; exit 2; }
if [[ "$AUTO_SYNC_GCS" -eq 1 ]]; then
  [[ "$SYNC_EVERY_STEPS" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid sync_every_steps: $SYNC_EVERY_STEPS" >&2; exit 2; }
  if (( SYNC_EVERY_STEPS <= 0 )); then
    echo "[ERROR] sync_every_steps must be >0 when auto sync is enabled" >&2
    exit 2
  fi
fi
[[ "$CUTOFF_LEN" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid cutoff_len: $CUTOFF_LEN" >&2; exit 2; }
[[ "$SEED" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid seed: $SEED" >&2; exit 2; }
if [[ "$HAS_GPU" -eq 1 ]] && (( CUTOFF_LEN < 512 )); then
  echo "[INFO] cutoff_len=$CUTOFF_LEN on GPU; you may increase to 512/1024 for longer-context training."
fi
if [[ "$HAS_GPU" -eq 0 ]] && (( CUTOFF_LEN > 512 )); then
  echo "[WARN] cutoff_len=$CUTOFF_LEN on CPU can be very slow."
fi

if [[ "$VAL_SIZE" != "0" ]] && ! [[ "$VAL_SIZE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "[ERROR] invalid val_size: $VAL_SIZE (use 0 or a positive number)" >&2
  exit 2
fi

if [[ "$DATASET_ROWS" -le 0 ]]; then
  echo "[ERROR] dataset has zero valid rows: $DATA_FILE" >&2
  exit 2
fi
EFFECTIVE_ROWS="$DATASET_ROWS"
if [[ -n "$MAX_SAMPLES" ]]; then
  [[ "$MAX_SAMPLES" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid --max-samples: $MAX_SAMPLES" >&2; exit 2; }
  if (( MAX_SAMPLES > 0 && MAX_SAMPLES < EFFECTIVE_ROWS )); then
    EFFECTIVE_ROWS="$MAX_SAMPLES"
  fi
fi
GLOBAL_BATCH=$((BATCH * GRAD_ACC))
STEPS_PER_EPOCH=$(( (EFFECTIVE_ROWS + GLOBAL_BATCH - 1) / GLOBAL_BATCH ))
if (( STEPS_PER_EPOCH < 1 )); then
  STEPS_PER_EPOCH=1
fi

if [[ -n "$MAX_STEPS" ]]; then
  EQUIV_EPOCH="$(python - <<PY
steps=float(${MAX_STEPS})
spe=float(${STEPS_PER_EPOCH})
print(f"{steps/spe:.2f}")
PY
)"
  awk "BEGIN{exit !($EQUIV_EPOCH>5.0)}" && echo "[WARN] equivalent epochs is high (~$EQUIV_EPOCH). Consider lower --max-steps or add more data."
else
  EQUIV_EPOCH="$NUM_TRAIN_EPOCHS"
fi

VAL_EST="$(
python - <<PY
import math
n = int(${EFFECTIVE_ROWS})
v = "${VAL_SIZE}"
val = 0
if v != "0":
    x = float(v)
    if x <= 0:
        raise SystemExit(2)
    if x < 1:
        val = max(1, int(round(n * x)))
    else:
        val = min(n, int(x))
print(val)
PY
)" || { echo "[ERROR] invalid val_size=$VAL_SIZE" >&2; exit 2; }
TRAIN_EST=$((EFFECTIVE_ROWS - VAL_EST))
if (( TRAIN_EST < 1 )); then
  echo "[ERROR] train samples becomes zero (rows=$EFFECTIVE_ROWS, val_size=$VAL_SIZE)" >&2
  exit 2
fi
if (( VAL_EST > 0 && VAL_EST < 200 )); then
  echo "[WARN] validation set is small (estimated $VAL_EST samples), eval_loss may be noisy."
fi

FP16_FLAG="false"
BF16_FLAG="false"
if [[ "$HAS_GPU" -eq 1 ]] && [[ "$CUDA_AVAILABLE" == "1" ]]; then
  BF16_SUPPORTED="$(python - <<'PY'
import torch
print("1" if torch.cuda.is_available() and torch.cuda.is_bf16_supported() else "0")
PY
)"
  if [[ "$BF16_SUPPORTED" == "1" ]]; then
    BF16_FLAG="true"
    FP16_FLAG="false"
  else
    BF16_FLAG="false"
    FP16_FLAG="true"
  fi
fi
echo "[INFO] mixed precision: bf16=$BF16_FLAG, fp16=$FP16_FLAG"

if [[ "$INTERACTIVE_MODE" -eq 1 ]] && is_tty; then
  pt_read_prompt SYNC_INPUT "Sync to GCS every N steps [default=$SYNC_EVERY_STEPS, 0/off=disable] (press Enter to use default by default): "
  if [[ -n "${SYNC_INPUT:-}" ]]; then
    SYNC_INPUT_LC="$(echo "$SYNC_INPUT" | tr '[:upper:]' '[:lower:]')"
    if [[ "$SYNC_INPUT_LC" == "0" || "$SYNC_INPUT_LC" == "off" || "$SYNC_INPUT_LC" == "disable" || "$SYNC_INPUT_LC" == "none" ]]; then
      AUTO_SYNC_GCS=0
      SYNC_EVERY_STEPS=0
    else
      AUTO_SYNC_GCS=1
      SYNC_EVERY_STEPS="$SYNC_INPUT"
    fi
  fi
fi

RESUME_FROM_CHECKPOINT=""
if [[ "$RESUME_MODE" == "auto" ]]; then
  if [[ -d "$OUT_DIR" ]]; then
    latest_ckpt="$(find "$OUT_DIR" -maxdepth 1 -type d -name 'checkpoint-*' | sed 's|.*/checkpoint-||' | sort -n | tail -n 1 || true)"
    if [[ -n "$latest_ckpt" ]]; then
      RESUME_FROM_CHECKPOINT="$OUT_DIR/checkpoint-$latest_ckpt"
    fi
  fi
elif [[ "$RESUME_MODE" != "never" ]]; then
  RESUME_FROM_CHECKPOINT="$RESUME_MODE"
fi

TRAIN_YAML="$CONFIG_DIR/train_poop_sft_lora.yaml"
echo "[INFO] effective training summary:"
echo "  run_name=$RUN_NAME"
echo "  run_dir=$RUN_DIR"
echo "  model=$MODEL_NAME"
echo "  data_file=$DATA_FILE"
echo "  rows_total=$DATASET_ROWS rows_effective=$EFFECTIVE_ROWS train_est=$TRAIN_EST val_est=$VAL_EST"
echo "  cutoff_len=$CUTOFF_LEN seed=$SEED"
echo "  lora_r=$LORA_R lora_alpha=$LORA_ALPHA"
echo "  lr=$LR batch=$BATCH grad_acc=$GRAD_ACC global_batch=$GLOBAL_BATCH"
if [[ -n "$MAX_STEPS" ]]; then
  echo "  max_steps=$MAX_STEPS (equiv_epoch~$EQUIV_EPOCH)"
else
  echo "  num_train_epochs=$NUM_TRAIN_EPOCHS"
fi
echo "  save_steps=$SAVE_STEPS eval_steps=$EVAL_STEPS val_size=$VAL_SIZE"

cat > "$TRAIN_YAML" <<YAML
### model
model_name_or_path: $MODEL_NAME

### method
stage: sft
do_train: true
finetuning_type: lora
lora_target: $LORA_TARGET
lora_rank: $LORA_R
lora_alpha: $LORA_ALPHA

### dataset
dataset: $DATASET_NAME
template: $TEMPLATE_NAME
cutoff_len: $CUTOFF_LEN
overwrite_cache: true
preprocessing_num_workers: 1

### output
output_dir: $OUT_DIR
overwrite_output_dir: false
logging_steps: 1
save_steps: $SAVE_STEPS
plot_loss: true

### train
per_device_train_batch_size: $BATCH
gradient_accumulation_steps: $GRAD_ACC
learning_rate: $LR
num_train_epochs: $NUM_TRAIN_EPOCHS
lr_scheduler_type: cosine
warmup_ratio: 0.1
seed: $SEED
data_seed: $SEED

### eval
val_size: $VAL_SIZE
per_device_eval_batch_size: 1
eval_strategy: steps
eval_steps: $EVAL_STEPS

### mixed precision
fp16: $FP16_FLAG
bf16: $BF16_FLAG
YAML

if [[ -n "$MAX_STEPS" ]]; then
  awk -v v="$MAX_STEPS" '
    BEGIN{done=0}
    /^num_train_epochs:/ && !done {print; print "max_steps: " v; done=1; next}
    {print}
  ' "$TRAIN_YAML" > "${TRAIN_YAML}.tmp" && mv "${TRAIN_YAML}.tmp" "$TRAIN_YAML"
fi

if [[ "$VAL_SIZE" == "0" ]]; then
  awk '
    /^### eval$/ {print; print "val_size: 0"; print "eval_strategy: no"; print "per_device_eval_batch_size: 1"; next}
    /^val_size:/ {next}
    /^eval_strategy:/ {next}
    /^eval_steps:/ {next}
    /^per_device_eval_batch_size:/ {next}
    {print}
  ' "$TRAIN_YAML" > "${TRAIN_YAML}.tmp" && mv "${TRAIN_YAML}.tmp" "$TRAIN_YAML"
fi

if [[ -n "$MAX_SAMPLES" ]]; then
  awk -v v="$MAX_SAMPLES" '
    BEGIN{done=0}
    /^overwrite_cache: true$/ && !done {print "max_samples: " v; done=1}
    {print}
  ' "$TRAIN_YAML" > "${TRAIN_YAML}.tmp" && mv "${TRAIN_YAML}.tmp" "$TRAIN_YAML"
  echo "[INFO] max_samples: $MAX_SAMPLES"
else
  echo "[INFO] max_samples: all (unset)"
fi

if [[ -n "$RESUME_FROM_CHECKPOINT" ]]; then
  {
    echo ""
    echo "### resume"
    echo "resume_from_checkpoint: $RESUME_FROM_CHECKPOINT"
  } >> "$TRAIN_YAML"
  echo "[INFO] resume_from_checkpoint: $RESUME_FROM_CHECKPOINT"
else
  echo "[INFO] resume_from_checkpoint: none"
fi

echo "[INFO] config: $TRAIN_YAML"
echo "[INFO] output: $OUT_DIR"
cat > "$RUN_META_FILE" <<EOF
LAST_RUN_TS=$(date +%Y%m%d_%H%M%S)
LAST_RUN_NAME=$RUN_NAME
LAST_RUN_DIR=$RUN_DIR
LAST_MODEL_NAME=$MODEL_NAME
LAST_DATA_FILE=$DATA_FILE
LAST_DATA_MODE=$DATA_MODE
LAST_DATA_ROWS=$DATASET_ROWS
LAST_EFFECTIVE_ROWS=$EFFECTIVE_ROWS
LAST_TRAIN_EST=$TRAIN_EST
LAST_VAL_EST=$VAL_EST
LAST_OUTPUT_DIR=$OUT_DIR
LAST_TRAIN_YAML=$TRAIN_YAML
LAST_RESUME_MODE=$RESUME_MODE
LAST_GCS_PREFIX=$GCS_PREFIX
LAST_CUTOFF_LEN=$CUTOFF_LEN
LAST_SEED=$SEED
LAST_VAL_SIZE=$VAL_SIZE
LAST_LORA_R=$LORA_R
LAST_LORA_ALPHA=$LORA_ALPHA
LAST_LEARNING_RATE=$LR
LAST_BATCH_SIZE=$BATCH
LAST_GRAD_ACC=$GRAD_ACC
LAST_SAVE_STEPS=$SAVE_STEPS
LAST_EVAL_STEPS=$EVAL_STEPS
LAST_NUM_TRAIN_EPOCHS=$NUM_TRAIN_EPOCHS
LAST_MAX_STEPS=${MAX_STEPS:-}
LAST_EQUIV_EPOCH=$EQUIV_EPOCH
EOF
echo "[INFO] run metadata: $RUN_META_FILE"

cat > "$RUN_META_DETAIL_FILE" <<EOF
RUN_TS=$(date +%Y%m%d_%H%M%S)
RUN_NAME=$RUN_NAME
RUN_DIR=$RUN_DIR
MODEL_NAME=$MODEL_NAME
DATA_FILE=$DATA_FILE
DATA_MODE=$DATA_MODE
OUTPUT_DIR=$OUT_DIR
TRAIN_YAML=$TRAIN_YAML
RESUME_MODE=$RESUME_MODE
GCS_PREFIX=$GCS_PREFIX
EOF
echo "[INFO] run detail metadata: $RUN_META_DETAIL_FILE"

# Start ETA monitor in background
bash "$BASE_DIR/scripts/monitor_hf_eta.sh" "$OUT_DIR" 15 &
MON_PID=$!

SYNC_PID=""
if [[ "$AUTO_SYNC_GCS" -eq 1 ]] && [[ -n "$GCS_PREFIX" ]]; then
  if check_cmd gsutil; then
    (
      set +e
      last_synced_step=0
      while true; do
        latest_ckpt="$(find "$OUT_DIR" -maxdepth 1 -type d -name 'checkpoint-*' | sed 's|.*/checkpoint-||' | sort -n | tail -n 1 || true)"
        if [[ -n "$latest_ckpt" ]] && [[ "$latest_ckpt" =~ ^[0-9]+$ ]]; then
          if (( latest_ckpt >= SYNC_EVERY_STEPS )) && (( latest_ckpt > last_synced_step )) && (( latest_ckpt % SYNC_EVERY_STEPS == 0 )); then
            mkdir -p "$OUT_DIR"
            gsutil -m rsync -r "$OUT_DIR" "$GCS_PREFIX/live_output" >/dev/null 2>&1 || true
            [[ -f "$TRAIN_YAML" ]] && gsutil cp "$TRAIN_YAML" "$GCS_PREFIX/train_poop_sft_lora.yaml" >/dev/null 2>&1 || true
            last_synced_step="$latest_ckpt"
            echo "[INFO] gcs auto-sync checkpoint step=$latest_ckpt"
          fi
        fi
        sleep 5
      done
    ) &
    SYNC_PID=$!
    echo "[INFO] gcs auto-sync loop started (pid=$SYNC_PID, sync_every_steps=$SYNC_EVERY_STEPS)"
  else
    echo "[WARN] gsutil not found, skip gcs auto-sync loop"
  fi
fi

cleanup_bg() {
  kill "$MON_PID" >/dev/null 2>&1 || true
  if [[ -n "${SYNC_PID:-}" ]]; then
    kill "$SYNC_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_bg EXIT

if command -v llamafactory-cli >/dev/null 2>&1; then
  llamafactory-cli train "$TRAIN_YAML"
else
  python -m llamafactory.cli train "$TRAIN_YAML"
fi

if [[ -n "$SYNC_PID" ]]; then
  echo "[INFO] final gcs sync..."
  gsutil -m rsync -r "$OUT_DIR" "$GCS_PREFIX/live_output" >/dev/null 2>&1 || true
  [[ -f "$TRAIN_YAML" ]] && gsutil cp "$TRAIN_YAML" "$GCS_PREFIX/train_poop_sft_lora.yaml" >/dev/null 2>&1 || true
fi

echo "[OK] training finished"
