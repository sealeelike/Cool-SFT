#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_PARENT_DIR="$(cd "$BASE_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/workspace.sh"

GLOBAL_CFG_FILE="${POOPTRAIN_GLOBAL_CONFIG_DIR:-$HOME/.config/pooptrain}/workspace.env"
DEFAULT_WORKSPACE_DIR="$BUNDLE_PARENT_DIR/poopworkspace"
WORK_DIR_INPUT="${POOPTRAIN_WORKSPACE_DIR:-}"
WORK_DIR_INPUT="$(pt_load_workspace_input "$WORK_DIR_INPUT" "$GLOBAL_CFG_FILE")"
WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"

PROFILE=""
AUTO_YES=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/clean_workspace.sh [options]

Options:
  --workspace-dir <name/path>   Override workspace dir
  --profile <name>              One-shot cleanup profile:
                                light | cache | checkpoints | output | deps | all
  --yes                         Skip confirmation prompt for profile mode
  --help                        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-dir=*)
      WORK_DIR_INPUT="${1#*=}"
      WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
      shift
      ;;
    --workspace-dir)
      [[ $# -ge 2 ]] || { echo "[ERROR] --workspace-dir needs a value" >&2; exit 2; }
      WORK_DIR_INPUT="$2"
      WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      shift
      ;;
    --profile)
      [[ $# -ge 2 ]] || { echo "[ERROR] --profile needs a value" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --yes)
      AUTO_YES=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "[WARN] unknown arg: $1"
      shift
      ;;
  esac
done

VENV_DIR="$WORK_DIR/venv"
LLF_DIR="$WORK_DIR/LLaMA-Factory"
HF_HOME_DIR="$WORK_DIR/hf_home"
PIP_CACHE_DIR="$WORK_DIR/pip_cache"
XDG_CACHE_DIR="$WORK_DIR/.cache"
TORCH_HOME_DIR="$WORK_DIR/torch_home"
BASE_MODELS_DIR="$WORK_DIR/base_models"
OUT_DIR="$WORK_DIR/output_poop_sft"
RUNS_DIR="$WORK_DIR/runs"
CONFIG_DIR="$WORK_DIR/configs"
TMP_DIR="$WORK_DIR/tmp"
RUN_META_FILE="$WORK_DIR/last_run.env"
MERGED_FILE="$WORK_DIR/merged_dataset.jsonl"
NORMALIZED_FILE="$WORK_DIR/normalized_dataset.jsonl"
SHUFFLED_FILE="$WORK_DIR/shuffled_dataset.jsonl"
SELECTED_LIST="$WORK_DIR/selected_files.list"

size_of() {
  local p="$1"
  if [[ -e "$p" ]]; then
    du -sh "$p" 2>/dev/null | awk '{print $1}'
  else
    echo "-"
  fi
}

print_layout() {
  echo "=== Workspace Layout ==="
  echo "workspace: $WORK_DIR"
  echo ""
  echo "[Training artifacts]"
  echo "  runs            : $(size_of "$RUNS_DIR")"
  echo "  output_poop_sft : $(size_of "$OUT_DIR")"
  echo "  configs         : $(size_of "$CONFIG_DIR")"
  echo "  last_run.env    : $(size_of "$RUN_META_FILE")"
  echo ""
  echo "[Dataset intermediates]"
  echo "  merged_dataset      : $(size_of "$MERGED_FILE")"
  echo "  normalized_dataset  : $(size_of "$NORMALIZED_FILE")"
  echo "  shuffled_dataset    : $(size_of "$SHUFFLED_FILE")"
  echo "  selected_files.list : $(size_of "$SELECTED_LIST")"
  echo ""
  echo "[Python/runtime dependencies]"
  echo "  venv           : $(size_of "$VENV_DIR")"
  echo "  LLaMA-Factory  : $(size_of "$LLF_DIR")"
  echo ""
  echo "[Model/cache]"
  echo "  hf_home        : $(size_of "$HF_HOME_DIR")"
  echo "  base_models    : $(size_of "$BASE_MODELS_DIR")"
  echo "  torch_home     : $(size_of "$TORCH_HOME_DIR")"
  echo "  pip_cache      : $(size_of "$PIP_CACHE_DIR")"
  echo "  .cache         : $(size_of "$XDG_CACHE_DIR")"
  echo ""
  echo "[Temp]"
  echo "  tmp            : $(size_of "$TMP_DIR")"
}

remove_path() {
  local p="$1"
  if [[ -e "$p" ]]; then
    rm -rf "$p"
    echo "[OK] removed: $p"
  else
    echo "[INFO] skip (not found): $p"
  fi
}

cleanup_light() {
  remove_path "$TMP_DIR"
  remove_path "$MERGED_FILE"
  remove_path "$NORMALIZED_FILE"
  remove_path "$SHUFFLED_FILE"
  remove_path "$SELECTED_LIST"
}

cleanup_cache() {
  remove_path "$HF_HOME_DIR"
  remove_path "$PIP_CACHE_DIR"
  remove_path "$XDG_CACHE_DIR"
  remove_path "$TORCH_HOME_DIR"
}

cleanup_checkpoints() {
  if [[ -d "$RUNS_DIR" ]]; then
    mapfile -t CKPTS < <(find "$RUNS_DIR" -type d -name 'checkpoint-*' | sort)
    if [[ "${#CKPTS[@]}" -gt 0 ]]; then
      for c in "${CKPTS[@]}"; do
        remove_path "$c"
      done
      return 0
    fi
  fi
  if [[ -d "$OUT_DIR" ]]; then
    mapfile -t CKPTS < <(find "$OUT_DIR" -maxdepth 1 -type d -name 'checkpoint-*' | sort)
    if [[ "${#CKPTS[@]}" -eq 0 ]]; then
      echo "[INFO] no checkpoints under: $OUT_DIR"
      return 0
    fi
    for c in "${CKPTS[@]}"; do
      remove_path "$c"
    done
  else
    echo "[INFO] output dir not found: $OUT_DIR"
  fi
}

cleanup_output() {
  remove_path "$OUT_DIR"
}

cleanup_deps() {
  remove_path "$VENV_DIR"
  remove_path "$LLF_DIR"
}

cleanup_all() {
  remove_path "$WORK_DIR"
}

confirm_or_exit() {
  local action="$1"
  if [[ "$AUTO_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "Proceed cleanup [$action]? [y/N]: " ans
  case "${ans:-N}" in
    y|Y|yes|YES) ;;
    *) echo "[INFO] cancelled"; exit 0 ;;
  esac
}

run_profile() {
  local profile="$1"
  case "$profile" in
    light)
      confirm_or_exit "light"
      cleanup_light
      ;;
    cache)
      confirm_or_exit "cache"
      cleanup_cache
      ;;
    checkpoints)
      confirm_or_exit "checkpoints"
      cleanup_checkpoints
      ;;
    output)
      confirm_or_exit "output"
      cleanup_output
      ;;
    deps)
      confirm_or_exit "deps"
      cleanup_deps
      ;;
    all)
      confirm_or_exit "all"
      cleanup_all
      ;;
    *)
      echo "[ERROR] invalid profile: $profile"
      echo "[ERROR] use one of: light | cache | checkpoints | output | deps | all"
      exit 2
      ;;
  esac
}

print_layout

if [[ -n "$PROFILE" ]]; then
  run_profile "$PROFILE"
  echo ""
  print_layout
  exit 0
fi

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "[ERROR] non-interactive mode requires --profile" >&2
  exit 2
fi

prompt_remove_items() {
  local title="$1"
  shift
  local items=("$@")
  if [[ "${#items[@]}" -eq 0 ]]; then
    echo "[INFO] no entries in: $title"
    return 0
  fi
  echo ""
  echo "=== $title ==="
  local i=1
  for p in "${items[@]}"; do
    echo "  [$i] $p ($(size_of "$p"))"
    i=$((i + 1))
  done
  read -r -p "Select items: Enter=cancel, 'all'=remove all, or indexes separated by space: " pick
  [[ -n "${pick:-}" ]] || { echo "[INFO] cancelled"; return 0; }

  local targets=()
  if [[ "$pick" == "all" || "$pick" == "ALL" ]]; then
    targets=("${items[@]}")
  else
    for tok in $pick; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#items[@]} )); then
        targets+=("${items[$((tok - 1))]}")
      else
        echo "[WARN] ignore invalid index: $tok"
      fi
    done
    if [[ "${#targets[@]}" -eq 0 ]]; then
      echo "[INFO] no valid selection"
      return 0
    fi
  fi

  echo "[INFO] selected for deletion:"
  for p in "${targets[@]}"; do
    echo "  - $p"
  done
  read -r -p "Confirm delete selected items? [y/N]: " ans
  case "${ans:-N}" in
    y|Y|yes|YES) ;;
    *) echo "[INFO] cancelled"; return 0 ;;
  esac
  for p in "${targets[@]}"; do
    remove_path "$p"
  done
}

while true; do
  echo ""
  echo "=== Cleanup Menu ==="
  echo "  1) Base models        (workspace/base_models/*)"
  echo "  2) Checkpoints        (runs/**/checkpoint-*)"
  echo "  3) Run outputs        (workspace/runs/*)"
  echo "  4) Caches             (hf_home/.cache/pip_cache/torch_home)"
  echo "  5) Dependencies       (venv + LLaMA-Factory)"
  echo "  6) Data intermediates (merged/normalized/shuffled/tmp)"
  echo "  7) Whole workspace    ($WORK_DIR)"
  echo "  8) Quick profiles     (light/cache/checkpoints/output/deps/all)"
  echo "  9) Refresh size panel"
  echo "  0) Exit"
  read -r -p "Choose action [0-9, default=0]: " menu
  menu="${menu:-0}"

  case "$menu" in
    1)
      mapfile -t ITEMS < <(find "$BASE_MODELS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
      prompt_remove_items "Base models" "${ITEMS[@]}"
      ;;
    2)
      mapfile -t ITEMS < <(find "$RUNS_DIR" -type d -name 'checkpoint-*' 2>/dev/null | sort -V)
      prompt_remove_items "Checkpoints" "${ITEMS[@]}"
      ;;
    3)
      mapfile -t ITEMS < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
      prompt_remove_items "Run outputs" "${ITEMS[@]}"
      ;;
    4)
      ITEMS=("$HF_HOME_DIR" "$PIP_CACHE_DIR" "$XDG_CACHE_DIR" "$TORCH_HOME_DIR")
      prompt_remove_items "Caches" "${ITEMS[@]}"
      ;;
    5)
      ITEMS=("$VENV_DIR" "$LLF_DIR")
      prompt_remove_items "Dependencies" "${ITEMS[@]}"
      ;;
    6)
      ITEMS=("$TMP_DIR" "$MERGED_FILE" "$NORMALIZED_FILE" "$SHUFFLED_FILE" "$SELECTED_LIST")
      prompt_remove_items "Data intermediates" "${ITEMS[@]}"
      ;;
    7)
      prompt_remove_items "Whole workspace" "$WORK_DIR"
      ;;
    8)
      echo "  1) light  2) cache  3) checkpoints  4) output  5) deps  6) all  0) back"
      read -r -p "Choose profile [0-6, default=0]: " pf
      pf="${pf:-0}"
      case "$pf" in
        1) run_profile light ;;
        2) run_profile cache ;;
        3) run_profile checkpoints ;;
        4) run_profile output ;;
        5) run_profile deps ;;
        6) run_profile all ;;
        0) ;;
        *) echo "[WARN] invalid profile selection: $pf" ;;
      esac
      ;;
    9)
      print_layout
      ;;
    0)
      echo "[INFO] exit"
      break
      ;;
    *)
      echo "[WARN] invalid selection: $menu"
      ;;
  esac
done
