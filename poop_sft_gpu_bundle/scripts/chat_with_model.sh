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
VENV_DIR="$WORK_DIR/venv"
HF_HOME_SCAN="${HF_HOME:-$WORK_DIR/hf_home}"
MODEL_NAME=""
ADAPTER_DIR=""
MAX_NEW_TOKENS=220
TEMPERATURE=0.8
TOP_P=0.9
REPETITION_PENALTY=1.05
SYSTEM_PROMPT=""
MODEL_SET=0
ADAPTER_SET=0

# Repair common SSH TTY erase-key mismatch so Backspace works in prompts.
pt_fix_tty_erase

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model=*)
      MODEL_NAME="${1#*=}"
      MODEL_SET=1
      shift
      ;;
    --model)
      [[ $# -ge 2 ]] || { echo "[ERROR] --model needs a value" >&2; exit 2; }
      MODEL_NAME="$2"
      MODEL_SET=1
      shift 2
      ;;
    --adapter=*)
      ADAPTER_DIR="${1#*=}"
      ADAPTER_SET=1
      shift
      ;;
    --workspace-dir=*)
      WORK_DIR_INPUT="${1#*=}"
      WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
      VENV_DIR="$WORK_DIR/venv"
      shift
      ;;
    --workspace-dir)
      [[ $# -ge 2 ]] || { echo "[ERROR] --workspace-dir needs a value" >&2; exit 2; }
      WORK_DIR_INPUT="$2"
      WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
      VENV_DIR="$WORK_DIR/venv"
      shift 2
      ;;
    --adapter)
      [[ $# -ge 2 ]] || { echo "[ERROR] --adapter needs a value" >&2; exit 2; }
      ADAPTER_DIR="$2"
      ADAPTER_SET=1
      shift 2
      ;;
    --max-new-tokens=*)
      MAX_NEW_TOKENS="${1#*=}"
      shift
      ;;
    --temperature=*)
      TEMPERATURE="${1#*=}"
      shift
      ;;
    --top-p=*)
      TOP_P="${1#*=}"
      shift
      ;;
    --repetition-penalty=*)
      REPETITION_PENALTY="${1#*=}"
      shift
      ;;
    --system=*)
      SYSTEM_PROMPT="${1#*=}"
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  ./scripts/chat_with_model.sh [options]

Options:
  --model <hf_model_id>         Base model id (auto-read from adapter if omitted)
  --adapter <path>              LoRA adapter dir (auto-discover + select if omitted)
  --workspace-dir <name/path>   Runtime workspace dir (default: sibling ./poopworkspace)
  --max-new-tokens <int>        Default: 220
  --temperature <float>         Default: 0.8
  --top-p <float>               Default: 0.9
  --repetition-penalty <float>  Default: 1.05
  --system <text>               Optional system prompt
EOF
      exit 0
      ;;
    *)
      echo "[WARN] unknown arg: $1"
      shift
      ;;
  esac
done

[[ -d "$VENV_DIR" ]] || { echo "[ERROR] venv not found: $VENV_DIR (run training script once first)" >&2; exit 2; }
echo "[INFO] workspace_dir: $WORK_DIR"

if [[ "$ADAPTER_SET" -eq 0 ]]; then
  if [[ -f "$WORK_DIR/last_run.env" ]]; then
    # shellcheck disable=SC1090
    source "$WORK_DIR/last_run.env" >/dev/null 2>&1 || true
    if [[ -n "${LAST_OUTPUT_DIR:-}" && -f "${LAST_OUTPUT_DIR:-}/adapter_config.json" ]]; then
      ADAPTER_DIR="$LAST_OUTPUT_DIR"
      ADAPTER_SET=1
      echo "[INFO] auto adapter (last run): $ADAPTER_DIR"
    fi
  fi
fi

if [[ "$ADAPTER_SET" -eq 0 ]]; then
  # Prefer the consolidated final adapter directory when available.
  if [[ -f "$WORK_DIR/output_poop_sft/adapter_config.json" ]]; then
    ADAPTER_DIR="$WORK_DIR/output_poop_sft"
    ADAPTER_SET=1
    echo "[INFO] auto adapter (final): $ADAPTER_DIR"
  fi
fi

if [[ "$ADAPTER_SET" -eq 0 ]]; then
  mapfile -t ADAPTER_CANDIDATES < <(
    {
      find "$PWD" -maxdepth 5 -type f -name adapter_config.json 2>/dev/null
      find "$WORK_DIR" -maxdepth 5 -type f -name adapter_config.json 2>/dev/null
    } | sed 's#/adapter_config\.json$##' | awk '!seen[$0]++'
  )

  if [[ "${#ADAPTER_CANDIDATES[@]}" -eq 0 ]]; then
    echo "[ERROR] no adapter found. pass --adapter <path>." >&2
    exit 2
  elif [[ "${#ADAPTER_CANDIDATES[@]}" -eq 1 ]]; then
    ADAPTER_DIR="${ADAPTER_CANDIDATES[0]}"
    echo "[INFO] auto adapter: $ADAPTER_DIR"
  else
    mapfile -t ADAPTER_CANDIDATES < <(
      printf '%s\n' "${ADAPTER_CANDIDATES[@]}" | awk '
        {
          s=-1
          if (match($0, /checkpoint-[0-9]+/)) {
            t=substr($0, RSTART, RLENGTH)
            sub(/^checkpoint-/, "", t)
            s=t+0
          }
          printf("%08d\t%s\n", 99999999-s, $0)
        }
      ' | sort -k1,1n -k2,2 | cut -f2-
    )
    echo "[INFO] choose adapter:"
    i=1
    for item in "${ADAPTER_CANDIDATES[@]}"; do
      echo "  [$i] $item"
      i=$((i+1))
    done
    read -rp "Select adapter index [1-${#ADAPTER_CANDIDATES[@]}, default=1(latest checkpoint)]: " pick
    pick="${pick:-1}"
    [[ "$pick" =~ ^[0-9]+$ ]] || { echo "[ERROR] invalid selection" >&2; exit 2; }
    [[ "$pick" -ge 1 && "$pick" -le "${#ADAPTER_CANDIDATES[@]}" ]] || { echo "[ERROR] out of range" >&2; exit 2; }
    ADAPTER_DIR="${ADAPTER_CANDIDATES[$((pick-1))]}"
  fi
fi

[[ -d "$ADAPTER_DIR" ]] || { echo "[ERROR] adapter dir not found: $ADAPTER_DIR" >&2; exit 2; }

if [[ "$MODEL_SET" -eq 0 ]]; then
  ADAPTER_CFG="$ADAPTER_DIR/adapter_config.json"
  if [[ -f "$ADAPTER_CFG" ]]; then
    MODEL_NAME="$(
      python3 - <<PY
import json
cfg = json.load(open("${ADAPTER_CFG}", encoding="utf-8"))
print(cfg.get("base_model_name_or_path", "").strip())
PY
)"
  fi
  if [[ -z "${MODEL_NAME:-}" ]]; then
    echo "[ERROR] cannot infer base model from: $ADAPTER_CFG" >&2
    echo "[ERROR] please pass --model <hf_model_id_or_local_path>" >&2
    exit 2
  fi
  echo "[INFO] auto base model from adapter: $MODEL_NAME"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

export HF_HOME="${HF_HOME:-$WORK_DIR/hf_home}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export TRANSFORMERS_CACHE="${TRANSFORMERS_CACHE:-$HF_HOME/transformers}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORK_DIR/.cache}"

python /dev/fd/3 3<<PY
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
from peft import PeftModel

model_name = "${MODEL_NAME}"
adapter_dir = "${ADAPTER_DIR}"
max_new_tokens = int("${MAX_NEW_TOKENS}")
temperature = float("${TEMPERATURE}")
top_p = float("${TOP_P}")
repetition_penalty = float("${REPETITION_PENALTY}")
system_prompt = """${SYSTEM_PROMPT}""".strip()

device = "cuda" if torch.cuda.is_available() else "cpu"
if device == "cuda":
    dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
else:
    dtype = torch.float32
print(f"[INFO] inference device={device}, dtype={dtype}")
if device == "cpu":
    print("[WARN] running inference on CPU; large models will be slow. Prefer GPU or quantized model.")

print(f"[INFO] loading base model: {model_name}")
tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
if tokenizer.pad_token_id is None and tokenizer.eos_token_id is not None:
    tokenizer.pad_token = tokenizer.eos_token
base_model = AutoModelForCausalLM.from_pretrained(
    model_name,
    dtype=dtype,
    trust_remote_code=True
)
print(f"[INFO] loading lora adapter: {adapter_dir}")
model = PeftModel.from_pretrained(base_model, adapter_dir)
model.to(device)
model.eval()

print("[INFO] interactive chat ready. Type /exit to quit, /clear to clear history.")

history = []
if system_prompt:
    history.append({"role": "system", "content": system_prompt})

while True:
    try:
        user_text = input("\\nYou> ").strip()
    except (KeyboardInterrupt, EOFError):
        print("\\n[INFO] bye")
        break

    if not user_text:
        continue
    if user_text.lower() in {"/exit", "exit", "quit"}:
        print("[INFO] bye")
        break
    if user_text.lower() == "/clear":
        history = [{"role": "system", "content": system_prompt}] if system_prompt else []
        print("[INFO] history cleared")
        continue

    history.append({"role": "user", "content": user_text})

    inputs = None
    try:
        input_ids = tokenizer.apply_chat_template(
            history,
            tokenize=True,
            add_generation_prompt=True,
            return_tensors="pt"
        )
        inputs = {"input_ids": input_ids.to(device)}
        if getattr(tokenizer, "pad_token_id", None) is not None:
            inputs["attention_mask"] = (inputs["input_ids"] != tokenizer.pad_token_id).long()
        else:
            inputs["attention_mask"] = torch.ones_like(inputs["input_ids"], dtype=torch.long)
    except Exception:
        turns = []
        if system_prompt:
            turns.append(f"System: {system_prompt}")
        for msg in history:
            if msg["role"] == "user":
                turns.append(f"User: {msg['content']}")
            elif msg["role"] == "assistant":
                turns.append(f"Assistant: {msg['content']}")
        turns.append("Assistant:")
        prompt = "\\n".join(turns)
        inputs = tokenizer(str(prompt), return_tensors="pt").to(device)

    with torch.no_grad():
        output_ids = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            do_sample=True,
            temperature=temperature,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
            pad_token_id=tokenizer.pad_token_id,
            eos_token_id=tokenizer.eos_token_id
        )

    new_tokens = output_ids[0][inputs["input_ids"].shape[-1]:]
    answer = tokenizer.decode(new_tokens, skip_special_tokens=True).strip()
    print(f"Model> {answer}")
    history.append({"role": "assistant", "content": answer})
PY
