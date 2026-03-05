#!/usr/bin/env bash

check_cmd() { command -v "$1" >/dev/null 2>&1; }
is_tty() { [[ -t 0 && -t 1 ]]; }

pt_fix_tty_erase() {
  if [[ -t 0 && -t 1 ]] && check_cmd stty; then
    stty sane >/dev/null 2>&1 || true
    stty erase '^?' >/dev/null 2>&1 || stty erase '^H' >/dev/null 2>&1 || true
  fi
}

pt_clean_input() {
  # Strip control chars (including ^H / DEL) that may appear in some SSH/Tty setups.
  printf '%s' "${1:-}" | tr -d '\000-\010\013\014\016-\037\177'
}

pt_read_prompt() {
  local __var_name="$1"
  local __prompt="$2"
  local __raw=""
  if [[ -t 0 && -t 1 ]]; then
    # Use readline in TTY to preserve normal line editing/backspace behavior.
    read -e -r -p "$__prompt" __raw || true
  else
    read -r -p "$__prompt" __raw || true
  fi
  __raw="$(pt_clean_input "$__raw")"
  printf -v "$__var_name" '%s' "$__raw"
}
