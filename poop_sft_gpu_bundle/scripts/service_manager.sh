#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_PREFIX="pooptrain-train"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/service_manager.sh start [--run-name <name>] [--confirm] [--allow-default] [run_train_job args...]
  ./scripts/service_manager.sh list
  ./scripts/service_manager.sh status <run-name>
  ./scripts/service_manager.sh logs <run-name> [--follow]
  ./scripts/service_manager.sh stop <run-name>
  ./scripts/service_manager.sh dashboard [--interval <sec>]

Notes:
- This script uses real systemd user services (not nohup/tmux/setsid).
- start passes args to run_train_job.sh and forces: --no-interactive --yes --run-name <name>
- start now requires --confirm. Empty/default launch is blocked unless --allow-default is provided.
- Example:
  ./scripts/service_manager.sh start --confirm --run-name qwen7b_r01 --workspace-dir ~/pooptrain/poopworkspace --model Qwen/Qwen2.5-7B --gcs-prefix gs://my-bucket/exports/test
USAGE
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] missing command: $1" >&2
    exit 2
  }
}

ensure_systemd_user() {
  if ! systemctl --user list-units >/dev/null 2>&1; then
    cat >&2 <<'ERR'
[ERROR] cannot access systemd user manager.
Try:
  1) login with a normal PAM session (SSH usually works)
  2) if needed: sudo loginctl enable-linger "$USER"
  3) re-login and retry
ERR
    exit 3
  fi
}

sanitize_name() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -cs 'A-Za-z0-9._-' '_')"
  raw="${raw##_}"
  raw="${raw%%_}"
  if [[ -z "$raw" ]]; then
    raw="run_$(date +%Y%m%d_%H%M%S)"
  fi
  printf '%s' "$raw"
}

unit_from_run_name() {
  local run_name="$1"
  local safe
  safe="$(sanitize_name "$run_name")"
  printf '%s' "${UNIT_PREFIX}-${safe}.service"
}

cmd_start() {
  ensure_cmd systemd-run
  ensure_cmd systemctl
  ensure_cmd bash
  ensure_systemd_user

  local run_name=""
  local confirm=0
  local allow_default=0
  local -a pass_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-name)
        [[ $# -ge 2 ]] || { echo "[ERROR] --run-name needs a value" >&2; exit 2; }
        run_name="$2"
        shift 2
        ;;
      --run-name=*)
        run_name="${1#*=}"
        shift
        ;;
      --confirm)
        confirm=1
        shift
        ;;
      --allow-default)
        allow_default=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        pass_args+=("$@")
        break
        ;;
      *)
        pass_args+=("$1")
        shift
        ;;
    esac
  done

  if [[ "$confirm" -ne 1 ]]; then
    echo "[ERROR] start requires explicit --confirm to avoid accidental training launch." >&2
    echo "[INFO] example: ./scripts/service_manager.sh start --confirm --run-name test --workspace-dir ~/pooptrain/poopworkspace --model Qwen/Qwen2.5-0.5B" >&2
    exit 2
  fi

  if [[ "${#pass_args[@]}" -eq 0 && "$allow_default" -ne 1 ]]; then
    echo "[ERROR] empty/default start is blocked. Provide run_train_job args or add --allow-default explicitly." >&2
    echo "[INFO] recommended minimum args: --workspace-dir <dir> --model <hf_model_id>" >&2
    exit 2
  fi

  if [[ -z "$run_name" ]]; then
    run_name="run_$(date +%Y%m%d_%H%M%S)"
  fi

  local unit
  unit="$(unit_from_run_name "$run_name")"

  if systemctl --user is-active --quiet "$unit"; then
    echo "[ERROR] unit already active: $unit" >&2
    exit 4
  fi

  local -a cmd
  cmd=(/usr/bin/env bash "$SCRIPT_DIR/run_train_job.sh" --no-interactive --yes --run-name "$run_name")
  cmd+=("${pass_args[@]}")

  echo "[INFO] starting service: $unit"
  echo "[INFO] run_name: $run_name"
  echo "[INFO] workdir: $BASE_DIR"
  echo "[INFO] cmd: ${cmd[*]}"

  systemd-run \
    --user \
    --unit "${unit%.service}" \
    --collect \
    --property="WorkingDirectory=$BASE_DIR" \
    --property="Restart=no" \
    --property="KillSignal=SIGINT" \
    --property="StandardOutput=journal" \
    --property="StandardError=journal" \
    "${cmd[@]}" >/dev/null

  echo "[OK] started: $unit"
  echo "[INFO] status: systemctl --user status $unit --no-pager"
  echo "[INFO] logs:   journalctl --user -u $unit -f"
}

cmd_dashboard() {
  ensure_cmd systemctl
  ensure_systemd_user
  local interval="${1:-3}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
    echo "[ERROR] dashboard interval must be positive integer seconds" >&2
    exit 2
  fi

  while true; do
    clear || true
    echo "=== poopTrain Service Dashboard ==="
    echo "time: $(date '+%F %T %Z')"
    echo
    echo "[Active/Recent Units]"
    systemctl --user list-units --type=service --all "${UNIT_PREFIX}-*" --no-pager | sed -n '1,30p'
    echo
    echo "[Latest last_run.env]"
    if [[ -f "$HOME/pooptrain/poopworkspace/last_run.env" ]]; then
      grep -E '^(LAST_RUN_NAME|LAST_MODEL_NAME|LAST_OUTPUT_DIR|LAST_GCS_PREFIX|LAST_RESUME_MODE)=' "$HOME/pooptrain/poopworkspace/last_run.env" || true
    else
      echo "no last_run.env found under ~/pooptrain/poopworkspace"
    fi
    echo
    echo "Commands: q=quit, r=refresh now, l=list units"
    read -r -t "$interval" -n 1 key || true
    case "${key:-}" in
      q|Q) break ;;
      l|L)
        echo
        systemctl --user list-units --type=service --all "${UNIT_PREFIX}-*" --no-pager
        echo
        read -r -n 1 -p "press any key to return..." _k || true
        ;;
      *) ;;
    esac
  done
}

cmd_list() {
  ensure_cmd systemctl
  ensure_systemd_user
  systemctl --user list-units --type=service --all "${UNIT_PREFIX}-*" --no-pager
}

cmd_status() {
  ensure_cmd systemctl
  ensure_systemd_user
  local run_name="${1:-}"
  [[ -n "$run_name" ]] || { echo "[ERROR] status requires <run-name>" >&2; exit 2; }
  local unit
  unit="$(unit_from_run_name "$run_name")"
  systemctl --user status "$unit" --no-pager
}

cmd_logs() {
  ensure_cmd journalctl
  ensure_systemd_user
  local run_name="${1:-}"
  [[ -n "$run_name" ]] || { echo "[ERROR] logs requires <run-name>" >&2; exit 2; }
  shift || true
  local follow=0
  if [[ "${1:-}" == "--follow" || "${1:-}" == "-f" ]]; then
    follow=1
  fi
  local unit
  unit="$(unit_from_run_name "$run_name")"
  if [[ "$follow" -eq 1 ]]; then
    journalctl --user -u "$unit" -f
  else
    journalctl --user -u "$unit" -n 200 --no-pager
  fi
}

cmd_stop() {
  ensure_cmd systemctl
  ensure_systemd_user
  local run_name="${1:-}"
  [[ -n "$run_name" ]] || { echo "[ERROR] stop requires <run-name>" >&2; exit 2; }
  local unit
  unit="$(unit_from_run_name "$run_name")"
  systemctl --user stop "$unit"
  echo "[OK] stopped: $unit"
}

main() {
  local sub="${1:-}"
  case "$sub" in
    start)
      shift || true
      cmd_start "$@"
      ;;
    list)
      shift || true
      cmd_list "$@"
      ;;
    status)
      shift || true
      cmd_status "$@"
      ;;
    logs)
      shift || true
      cmd_logs "$@"
      ;;
    stop)
      shift || true
      cmd_stop "$@"
      ;;
    dashboard)
      shift || true
      if [[ "${1:-}" == "--interval" ]]; then
        shift
      fi
      cmd_dashboard "${1:-3}"
      ;;
    --help|-h|help|"")
      usage
      ;;
    *)
      echo "[ERROR] unknown subcommand: $sub" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
