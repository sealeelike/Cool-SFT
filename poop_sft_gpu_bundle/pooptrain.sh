#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
cd "$BASE_DIR"

# colors
C_RED='\033[0;31m'
C_GRN='\033[0;32m'
C_YLW='\033[0;33m'
C_RST='\033[0m'

info() { echo -e "${C_GRN}[INFO]${C_RST} $*"; }
warn() { echo -e "${C_YLW}[WARN]${C_RST} $*"; }
err()  { echo -e "${C_RED}[ERR ]${C_RST} $*"; }

prompt() {
  local msg="$1"; shift || true
  read -e -r -p "$msg" "$@"
}

pause() { read -r -p "Press Enter to continue..." _ || true; }

show_header() {
  clear || true
  echo "========================================"
  echo " poopTrain TUI (systemd backend)"
  echo " workspace default: ~/pooptrain/poopworkspace"
  echo "========================================"
  echo
}

run_precheck() {
  show_header
  prompt "GCS prefix (Enter=skip): " GCS
  local args=()
  [[ -n "${GCS:-}" ]] && args+=(--gcs-prefix "$GCS")
  info "running precheck_env.sh ${args[*]}"
  "$SCRIPT_DIR/scripts/precheck_env.sh" "${args[@]}" || true
  pause
}

start_training() {
  show_header
  prompt "Run name (default auto): " RUN_NAME
  prompt "Workspace dir (Enter=default): " WORKDIR
  prompt "Base model id (Enter=Qwen/Qwen2.5-0.5B): " MODEL
  prompt "GCS prefix (Enter=skip): " GCS
  prompt "Extra args to run_train_job (optional): " EXTRA

  local args=(--confirm)
  [[ -n "${RUN_NAME:-}" ]] && args+=(--run-name "$RUN_NAME")
  [[ -n "${WORKDIR:-}" ]] && args+=(--workspace-dir "$WORKDIR")
  [[ -n "${MODEL:-}" ]] && args+=(--model "$MODEL")
  [[ -n "${GCS:-}" ]] && args+=(--gcs-prefix "$GCS")
  if [[ -n "${EXTRA:-}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_ARR=($EXTRA)
    args+=("${EXTRA_ARR[@]}")
  fi
  info "service_manager start ${args[*]}"
  "$SCRIPT_DIR/scripts/service_manager.sh" start "${args[@]}"
  pause
}

manage_services() {
  while true; do
    show_header
    echo "[Services]"
    mapfile -t UNITS < <(systemctl --user list-units --type=service --all "pooptrain-train-*" --no-pager --no-legend 2>/dev/null | awk '{print $1 ":" $3 ":" $4}')
    if [[ "${#UNITS[@]}" -eq 0 ]]; then
      echo "  (no pooptrain-train-* services)"
    else
      local idx=1
      for u in "${UNITS[@]}"; do
        IFS=':' read -r name load sub <<<"$u"
        echo "  [$idx] $name  ($sub)"
        idx=$((idx+1))
      done
    fi
    echo
    echo "1) status   2) logs(follow)   3) stop   0) back"
    read -r -p "Choose [0-3]: " ch
    case "${ch:-0}" in
      1)
        if [[ "${#UNITS[@]}" -eq 0 ]]; then warn "no services"; pause; continue; fi
        read -r -p "Pick index or run name: " rn
        if [[ "$rn" =~ ^[0-9]+$ ]] && (( rn>=1 && rn<=${#UNITS[@]} )); then
          IFS=':' read -r name _ _ <<<"${UNITS[$((rn-1))]}"
          rn="${name#pooptrain-train-}"; rn="${rn%.service}"
        fi
        [[ -n "$rn" ]] && "$SCRIPT_DIR/scripts/service_manager.sh" status "$rn" || warn "empty selection"
        pause;;
      2)
        if [[ "${#UNITS[@]}" -eq 0 ]]; then warn "no services"; pause; continue; fi
        read -r -p "Pick index or run name: " rn
        if [[ "$rn" =~ ^[0-9]+$ ]] && (( rn>=1 && rn<=${#UNITS[@]} )); then
          IFS=':' read -r name _ _ <<<"${UNITS[$((rn-1))]}"
          rn="${name#pooptrain-train-}"; rn="${rn%.service}"
        fi
        [[ -n "$rn" ]] && "$SCRIPT_DIR/scripts/service_manager.sh" logs "$rn" --follow || warn "empty selection"
        ;;
      3)
        if [[ "${#UNITS[@]}" -eq 0 ]]; then warn "no services"; pause; continue; fi
        read -r -p "Pick index or run name: " rn
        if [[ "$rn" =~ ^[0-9]+$ ]] && (( rn>=1 && rn<=${#UNITS[@]} )); then
          IFS=':' read -r name _ _ <<<"${UNITS[$((rn-1))]}"
          rn="${name#pooptrain-train-}"; rn="${rn%.service}"
        fi
        [[ -n "$rn" ]] && "$SCRIPT_DIR/scripts/service_manager.sh" stop "$rn" || warn "empty selection"
        pause;;
      0) break;;
      *) warn "invalid";;
    esac
  done
}

recent_runs() {
  show_header
  local runs_dir="$HOME/pooptrain/poopworkspace/runs"
  if [[ -d "$runs_dir" ]]; then
    find "$runs_dir" -maxdepth 1 -mindepth 1 -type d | sort | tail -n 5 | while read -r r; do
      echo "$(basename "$r")";
    done
  else
    warn "runs dir not found: $runs_dir"
  fi
  read -r -p "Inspect a run? enter name or blank to skip: " rn
  if [[ -n "$rn" && -d "$runs_dir/$rn" ]]; then
    ls "$runs_dir/$rn"
    if [[ -f "$runs_dir/$rn/run.env" ]]; then
      echo "--- run.env ---"; cat "$runs_dir/$rn/run.env"; echo "--------------"
    fi
    if [[ -f "$runs_dir/$rn/runtime.json" ]]; then
      echo "--- runtime.json ---"; cat "$runs_dir/$rn/runtime.json"; echo "--------------"
    fi
    if [[ -f "$runs_dir/$rn/output_poop_sft/trainer_log.jsonl" ]]; then
      echo "tail trainer_log.jsonl:"; tail -n 20 "$runs_dir/$rn/output_poop_sft/trainer_log.jsonl"
    fi
  fi
  pause
}

sync_gcs() {
  show_header
  prompt "GCS prefix (e.g. gs://bucket/exports/run): " GCS
  prompt "Output dir (Enter=last run from last_run.env): " OUT
  if [[ -z "${OUT:-}" && -f "$HOME/pooptrain/poopworkspace/last_run.env" ]]; then
    source "$HOME/pooptrain/poopworkspace/last_run.env" 2>/dev/null || true
    OUT="${LAST_OUTPUT_DIR:-}"
  fi
  [[ -z "$GCS" ]] && { warn "GCS prefix required"; pause; return; }
  [[ -z "$OUT" ]] && { warn "output dir required"; pause; return; }
  info "export_to_gcs.sh $GCS $OUT"
  "$SCRIPT_DIR/scripts/export_to_gcs.sh" "$GCS" "$OUT" || true
  pause
}

cleanup_menu() {
  show_header
  echo "Delegating to scripts/clean_workspace.sh"
  "$SCRIPT_DIR/scripts/clean_workspace.sh"
}

main_menu() {
  while true; do
    show_header
    echo "1) Env check"
    echo "2) Start training (systemd)"
    echo "3) Manage running tasks"
    echo "4) Recent runs"
    echo "5) Sync to GCS"
    echo "6) Cleanup"
    echo "0) Exit"
    read -r -p "Choose [0-6]: " choice
    case "${choice:-0}" in
      1) run_precheck ;;
      2) start_training ;;
      3) manage_services ;;
      4) recent_runs ;;
      5) sync_gcs ;;
      6) cleanup_menu ;;
      0) exit 0 ;;
      *) warn "invalid choice"; pause ;;
    esac
  done
}

main_menu
