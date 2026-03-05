#!/usr/bin/env bash

pick_model_id_interactive() {
  local current="$1"
  local default_choice="1"
  local MODEL_CHOICE=""
  local MODEL_INPUT=""
  echo "  [1] Qwen/Qwen2.5-0.5B (default)" >&2
  echo "  [2] Qwen/Qwen2.5-1.5B" >&2
  echo "  [3] Qwen/Qwen2.5-3B" >&2
  echo "  [4] Qwen/Qwen2.5-7B" >&2
  echo "  [5] custom (manual input)" >&2
  if [[ "$current" == "Qwen/Qwen2.5-1.5B" ]]; then
    default_choice="2"
  elif [[ "$current" == "Qwen/Qwen2.5-3B" ]]; then
    default_choice="3"
  elif [[ "$current" == "Qwen/Qwen2.5-7B" ]]; then
    default_choice="4"
  elif [[ "$current" != "Qwen/Qwen2.5-0.5B" ]]; then
    default_choice="5"
  fi
  while true; do
    pt_read_prompt MODEL_CHOICE "Choose model index [1/2/3/4/5, b=back, default=${default_choice}] (press Enter to use default by default): "
    MODEL_CHOICE="${MODEL_CHOICE:-$default_choice}"
    case "$MODEL_CHOICE" in
      1) echo "Qwen/Qwen2.5-0.5B"; return 0 ;;
      2) echo "Qwen/Qwen2.5-1.5B"; return 0 ;;
      3) echo "Qwen/Qwen2.5-3B"; return 0 ;;
      4) echo "Qwen/Qwen2.5-7B"; return 0 ;;
      b|B) echo "__BACK__"; return 0 ;;
      5)
        pt_read_prompt MODEL_INPUT "Enter HuggingFace model id [default=${current}, b=back] (press Enter to keep current by default): "
        if [[ "$MODEL_INPUT" == "b" || "$MODEL_INPUT" == "B" ]]; then
          continue
        fi
        if [[ -n "${MODEL_INPUT:-}" ]]; then
          echo "$MODEL_INPUT"
        else
          echo "$current"
        fi
        return 0
        ;;
      *)
        echo "[WARN] invalid model selection: $MODEL_CHOICE" >&2
        ;;
    esac
  done
}

build_data_selection_interactive() {
  local default_dir="$BASE_DIR/data"
  local selected_dir="$default_dir"
  local mode_choice=""
  local default_count="0"
  local custom_dir=""
  local -a candidates=()
  local -a selected=()
  local first_pick=""
  local pick=""
  local n=""

  default_count="$(find "$default_dir" -type f -name '*.jsonl' | wc -l | tr -d ' ')"
  while true; do
    echo "[INFO] dataset path selection:"
    echo "  1) use default path: $default_dir (jsonl: $default_count)"
    echo "  2) use custom path"
    echo "  b) back"
    while true; do
      pt_read_prompt mode_choice "Choose dataset path [1/2, b=back, default=1] (press Enter to use option 1 by default): "
      mode_choice="${mode_choice:-1}"
      if [[ "$mode_choice" == "1" ]]; then
        selected_dir="$default_dir"
        break
      elif [[ "$mode_choice" == "2" ]]; then
        while true; do
          pt_read_prompt custom_dir "Enter dataset directory path [b=back]: "
          if [[ "$custom_dir" == "b" || "$custom_dir" == "B" ]]; then
            custom_dir=""
            break
          fi
          if [[ -z "${custom_dir:-}" ]]; then
            echo "[WARN] empty dataset path, please retry"
            continue
          fi
          if [[ "$custom_dir" = /* ]]; then
            selected_dir="$custom_dir"
          else
            selected_dir="$BASE_DIR/$custom_dir"
          fi
          break
        done
        [[ -n "$custom_dir" ]] && break
      elif [[ "$mode_choice" == "b" || "$mode_choice" == "B" ]]; then
        return 10
      else
        echo "[WARN] invalid dataset path option: $mode_choice"
      fi
    done

    [[ -d "$selected_dir" ]] || { echo "[WARN] dataset directory not found: $selected_dir"; continue; }
    mapfile -t candidates < <(find "$selected_dir" -type f -name '*.jsonl' | sort)
    if [[ "${#candidates[@]}" -eq 0 ]]; then
      echo "[WARN] no jsonl found under: $selected_dir"
      continue
    fi

    echo "[INFO] detected jsonl files: ${#candidates[@]}"
    n=1
    for f in "${candidates[@]}"; do
      echo "  [$n] $f"
      n=$((n + 1))
    done
    echo "  [b] back"

    selected=()
    pt_read_prompt first_pick "Select files: Enter=all, one index each time, b=back (press Enter to select all by default): "
    if [[ "$first_pick" == "b" || "$first_pick" == "B" ]]; then
      continue
    fi
    if [[ -z "${first_pick:-}" ]]; then
      DATA_MODE="all"
      DATA_FILE="$selected_dir"
      return 0
    fi

    while true; do
      pick="$first_pick"
      first_pick=""
      if [[ "$pick" == "b" || "$pick" == "B" ]]; then
        selected=()
        break
      fi
      if [[ ! "$pick" =~ ^[0-9]+$ ]]; then
        echo "[WARN] invalid index: $pick"
      else
        if (( pick >= 1 && pick <= ${#candidates[@]} )); then
          selected+=("${candidates[$((pick - 1))]}")
          echo "[INFO] added: ${candidates[$((pick - 1))]}"
        else
          echo "[WARN] index out of range: $pick"
        fi
      fi
      pt_read_prompt pick "Next index (blank=finish, b=back) (press Enter to finish by default): "
      [[ -n "${pick:-}" ]] || break
      first_pick="$pick"
    done

    if [[ "${#selected[@]}" -eq 0 ]]; then
      continue
    fi

    DATA_MODE="selected"
    DATA_FILE="$WORK_DIR/selected_files.list"
    printf "%s\n" "${selected[@]}" > "$DATA_FILE"
    echo "[INFO] selected files count: ${#selected[@]}"
    return 0
  done
}
