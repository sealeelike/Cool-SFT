#!/usr/bin/env bash

pt_load_workspace_input() {
  local raw="${1:-}"
  local cfg_file="${2:-}"
  if [[ -n "$raw" ]]; then
    echo "$raw"
    return 0
  fi
  if [[ -n "$cfg_file" ]] && [[ -f "$cfg_file" ]]; then
    (
      set +u
      # shellcheck disable=SC1090
      source "$cfg_file" >/dev/null 2>&1 || true
      printf '%s' "${POOPTRAIN_WORKSPACE_DIR:-}"
    )
    return 0
  fi
  echo ""
}

pt_resolve_workspace_dir() {
  local base_dir="$1"
  local bundle_parent_dir="$2"
  local raw="${3:-}"
  local default_dir="${4:-$bundle_parent_dir/poopworkspace}"
  if [[ -z "$raw" ]]; then
    echo "$default_dir"
    return 0
  fi
  if [[ "$raw" == "~"* ]]; then
    raw="${HOME}${raw#\~}"
  fi
  if [[ "$raw" = /* ]]; then
    echo "$raw"
  elif [[ "$raw" == *"/"* ]]; then
    echo "$base_dir/$raw"
  else
    echo "$bundle_parent_dir/$raw"
  fi
}

pt_persist_workspace_choice() {
  local work_dir="$1"
  local global_cfg_dir="$2"
  local global_cfg_file="$3"
  mkdir -p "$global_cfg_dir"
  cat > "$global_cfg_file" <<EOF
POOPTRAIN_WORKSPACE_DIR="$work_dir"
EOF
}
