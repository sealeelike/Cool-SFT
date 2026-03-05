#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_PARENT_DIR="$(cd "$BASE_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/workspace.sh"
GLOBAL_CFG_DIR="${POOPTRAIN_GLOBAL_CONFIG_DIR:-$HOME/.config/pooptrain}"
GLOBAL_CFG_FILE="$GLOBAL_CFG_DIR/workspace.env"
DEFAULT_WORKSPACE_NAME="poopworkspace"
DEFAULT_WORKSPACE_DIR="$BUNDLE_PARENT_DIR/$DEFAULT_WORKSPACE_NAME"
WORK_DIR_INPUT="${POOPTRAIN_WORKSPACE_DIR:-}"
WORK_DIR_INPUT="$(pt_load_workspace_input "$WORK_DIR_INPUT" "$GLOBAL_CFG_FILE")"
WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"

VENV_DIR="$WORK_DIR/venv"
LLF_DIR="$WORK_DIR/LLaMA-Factory"
DATA_FILE="$BASE_DIR/data/instructions_gpt_94_v2.jsonl"
DATA_DIR="$BASE_DIR/data"
DATA_MODE="all"
GCS_PREFIX=""
SHUTDOWN_ON_FAIL=0
AUTO_FIX=1
PREPARE_PYTHON=0
FORCE_TORCH_REINSTALL=0
PREPARE_PYTHON_FORCE=0
DRIVER_REBOOT_REQUIRED=0
PREPARE_PYTHON_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gcs-prefix=*)
      GCS_PREFIX="${1#*=}"
      shift
      ;;
    --workspace-dir=*)
      WORK_DIR_INPUT="${1#*=}"
      shift
      ;;
    --workspace-dir)
      [[ $# -ge 2 ]] || { echo "[WARN] --workspace-dir needs a value"; break; }
      WORK_DIR_INPUT="$2"
      shift 2
      ;;
    --gcs-prefix)
      [[ $# -ge 2 ]] || { echo "[WARN] --gcs-prefix needs a value"; break; }
      GCS_PREFIX="$2"
      shift 2
      ;;
    --gcs-path=*)
      GCS_PREFIX="${1#*=}"
      shift
      ;;
    --gcs-path)
      [[ $# -ge 2 ]] || { echo "[WARN] --gcs-path needs a value"; break; }
      GCS_PREFIX="$2"
      shift 2
      ;;
    --data-file=*)
      DATA_FILE="${1#*=}"
      DATA_MODE="single"
      shift
      ;;
    --data-file)
      [[ $# -ge 2 ]] || { echo "[WARN] --data-file needs a value"; break; }
      DATA_FILE="$2"
      DATA_MODE="single"
      shift 2
      ;;
    --data-mode=*)
      DATA_MODE="${1#*=}"
      shift
      ;;
    --data-mode)
      [[ $# -ge 2 ]] || { echo "[WARN] --data-mode needs a value"; break; }
      DATA_MODE="$2"
      shift 2
      ;;
    --shutdown-on-fail)
      SHUTDOWN_ON_FAIL=1
      shift
      ;;
    --no-auto-fix)
      AUTO_FIX=0
      shift
      ;;
    --prepare-python)
      PREPARE_PYTHON=1
      shift
      ;;
    --prepare-python-only)
      PREPARE_PYTHON=1
      PREPARE_PYTHON_ONLY=1
      shift
      ;;
    --prepare-python-force)
      PREPARE_PYTHON=1
      PREPARE_PYTHON_FORCE=1
      shift
      ;;
    --force-torch-reinstall)
      FORCE_TORCH_REINSTALL=1
      shift
      ;;
    *)
      echo "[WARN] unknown arg: $1"
      shift
      ;;
  esac
done

WORK_DIR="$(pt_resolve_workspace_dir "$BASE_DIR" "$BUNDLE_PARENT_DIR" "$WORK_DIR_INPUT" "$DEFAULT_WORKSPACE_DIR")"
VENV_DIR="$WORK_DIR/venv"
LLF_DIR="$WORK_DIR/LLaMA-Factory"
pt_persist_workspace_choice "$WORK_DIR" "$GLOBAL_CFG_DIR" "$GLOBAL_CFG_FILE"

fail() {
  echo "[ERROR] $*" >&2
  if [[ "$SHUTDOWN_ON_FAIL" -eq 1 ]]; then
    echo "[INFO] precheck failed, shutdown in 5s..." >&2
    sleep 5
    sudo shutdown -h now
  fi
  exit 2
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

validate_gcs_prefix() {
  [[ "$1" =~ ^gs://[^/]+(/.*)?$ ]]
}

apt_install() {
  local pkg="$1"
  if [[ "$AUTO_FIX" -ne 1 ]]; then
    return 1
  fi
  if ! check_cmd apt-get; then
    return 1
  fi
  if check_cmd sudo; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || return 1
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 || return 1
  elif [[ "$(id -u)" -eq 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  return 0
}

print_disk_row() {
  local path="$1"
  local label="$2"
  if df -h "$path" >/dev/null 2>&1; then
    local row
    row="$(df -h "$path" | awk 'NR==2 {print $1" "$2" "$3" "$4" "$5" "$6}')"
    echo "$label: $row"
  fi
}

has_nvidia_pci() {
  if ! check_cmd lspci; then
    return 1
  fi
  lspci | grep -Eiq 'nvidia|3d controller.*nvidia|vga compatible controller.*nvidia'
}

if [[ "$PREPARE_PYTHON_ONLY" -ne 1 ]]; then
  echo "=== Precheck: Environment ==="
  check_cmd python3 || fail "python3 not found"
  check_cmd git || fail "git not found"
  echo "Python: $(python3 --version)"
  echo "Git: $(git --version)"
  echo "Workspace: $WORK_DIR"
  echo "CPU cores: $(getconf _NPROCESSORS_ONLN || echo 1)"
  echo "Memory: $(awk '/MemTotal/ {printf "%.2f GiB", $2/1024/1024}' /proc/meminfo)"
  echo "Disk free (project fs): $(df -h "$BASE_DIR" | awk 'NR==2 {print $4}')"
  echo "=== Precheck: Storage Layout ==="
  print_disk_row "/" "system_fs"
  print_disk_row "$BASE_DIR" "project_fs"
  print_disk_row "/tmp" "tmp_fs"
  if check_cmd lsblk; then
    echo "block_devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed -n '1,20p'
  fi
  if check_cmd nvidia-smi; then
    echo "GPU:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true
  else
    echo "GPU: not detected"
  fi

  echo "=== Precheck: GPU Driver ==="
  NVIDIA_PCI_PRESENT=0
  if has_nvidia_pci; then
    NVIDIA_PCI_PRESENT=1
    echo "nvidia_pci: detected"
  else
    echo "nvidia_pci: not detected"
  fi

  if [[ "$NVIDIA_PCI_PRESENT" -eq 1 ]] && ! check_cmd nvidia-smi; then
    echo "[WARN] NVIDIA device detected but nvidia-smi not available (driver likely missing)."
    if [[ "$AUTO_FIX" -eq 1 ]]; then
      echo "[INFO] trying auto-fix: install ubuntu-drivers-common and run ubuntu-drivers autoinstall"
      apt_install "ubuntu-drivers-common" || fail "failed to install ubuntu-drivers-common"
      if check_cmd ubuntu-drivers; then
        if check_cmd sudo; then
          sudo ubuntu-drivers autoinstall || fail "ubuntu-drivers autoinstall failed"
        elif [[ "$(id -u)" -eq 0 ]]; then
          ubuntu-drivers autoinstall || fail "ubuntu-drivers autoinstall failed"
        else
          fail "need sudo/root to run ubuntu-drivers autoinstall"
        fi
        DRIVER_REBOOT_REQUIRED=1
        echo "[WARN] GPU driver install completed, reboot required."
      else
        fail "ubuntu-drivers command unavailable after install"
      fi
    else
      fail "NVIDIA GPU detected but driver not ready. install ubuntu-drivers and reboot."
    fi
  fi

  if [[ "$DRIVER_REBOOT_REQUIRED" -eq 1 ]]; then
    fail "reboot required after GPU driver install, then rerun script"
  fi
fi

echo "=== Precheck: Python venv ==="
if ! python3 - <<'PY' >/dev/null 2>&1
import ensurepip
import venv
print("ok")
PY
then
  py_venv_pkg="$(python3 - <<'PY'
import sys
print(f"python{sys.version_info.major}.{sys.version_info.minor}-venv")
PY
)"
  echo "[WARN] python venv unavailable, trying auto-fix packages: $py_venv_pkg / python3-venv"
  apt_install "$py_venv_pkg" || apt_install "python3-venv" || fail "python3 venv unavailable and auto-fix failed (install $py_venv_pkg or python3-venv)"
fi
mkdir -p "$WORK_DIR/tmp"
tmp_venv_dir="$(mktemp -d "$WORK_DIR/tmp/pooptrain_venv_check_XXXXXX")"
if ! python3 -m venv "$tmp_venv_dir" >/dev/null 2>&1; then
  rm -rf "$tmp_venv_dir"
  py_venv_pkg="$(python3 - <<'PY'
import sys
print(f"python{sys.version_info.major}.{sys.version_info.minor}-venv")
PY
)"
  echo "[WARN] python3 -m venv failed, trying auto-fix packages: $py_venv_pkg / python3-venv"
  apt_install "$py_venv_pkg" || apt_install "python3-venv" || fail "python3 -m venv failed and auto-fix failed (install $py_venv_pkg or python3-venv)"
  tmp_venv_dir="$(mktemp -d "$WORK_DIR/tmp/pooptrain_venv_check_XXXXXX")"
  python3 -m venv "$tmp_venv_dir" >/dev/null 2>&1 || { rm -rf "$tmp_venv_dir"; fail "python3 -m venv still failing after auto-fix"; }
fi
rm -rf "$tmp_venv_dir"
echo "venv creation: ok"

if [[ "$PREPARE_PYTHON_ONLY" -ne 1 ]]; then
echo "=== Precheck: Dataset ==="
if [[ "$DATA_MODE" == "all" ]]; then
  mapfile -t DATA_FILES < <(find "$DATA_DIR" -type f -name '*.jsonl' | sort)
  [[ "${#DATA_FILES[@]}" -gt 0 ]] || fail "no jsonl files found in: $DATA_DIR"
  DATA_FILE_LIST="$(printf "%s\n" "${DATA_FILES[@]}")"
  DATA_FILE_LIST_ENV="$DATA_FILE_LIST" python3 - <<'PY' || exit 2
import json, os
files = [x for x in os.environ.get("DATA_FILE_LIST_ENV", "").splitlines() if x.strip()]
ok = 0
for p in files:
    with open(p, encoding='utf-8') as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if not all(k in obj for k in ('instruction', 'input', 'output')):
                raise SystemExit(f'missing keys in {p} at line {i}')
            ok += 1
print(f'dataset_files={len(files)}')
print(f'dataset_valid_rows={ok}')
PY
else
  [[ -f "$DATA_FILE" ]] || fail "dataset missing: $DATA_FILE"
  DATA_FILE_ENV="$DATA_FILE" python3 - <<'PY' || exit 2
import json
p=__import__('os').environ['DATA_FILE_ENV']
ok=0
with open(p,encoding='utf-8') as f:
    for i,line in enumerate(f,1):
        line=line.strip()
        if not line:
            continue
        obj=json.loads(line)
        if not all(k in obj for k in ('instruction','input','output')):
            raise SystemExit(f'missing keys at line {i}')
        ok+=1
print(f'dataset_valid_rows={ok}')
PY
fi

echo "=== Precheck: Network Basics ==="
if check_cmd curl; then
  curl -I --connect-timeout 5 https://pypi.org >/dev/null 2>&1 && echo "pypi reachable" || echo "[WARN] pypi unreachable"
  curl -I --connect-timeout 5 https://huggingface.co >/dev/null 2>&1 && echo "huggingface reachable" || echo "[WARN] huggingface unreachable"
else
  echo "[WARN] curl not found, skip network probe"
fi

if [[ -n "$GCS_PREFIX" ]]; then
  echo "=== Precheck: GCS ==="
  validate_gcs_prefix "$GCS_PREFIX" || fail "invalid --gcs-prefix: $GCS_PREFIX"
  if ! check_cmd gsutil; then
    echo "[WARN] gsutil not found, trying auto-fix package: google-cloud-cli"
    apt_install "google-cloud-cli" || fail "gsutil not found and auto-fix failed (install google-cloud-cli)"
  fi
  bucket="$(echo "$GCS_PREFIX" | awk -F/ '{print $1"//"$3}')"
  probe="$GCS_PREFIX/_probe_$(date +%s)_$$.txt"
  mkdir -p "$WORK_DIR/tmp"
  tmp="$WORK_DIR/tmp/gcs_probe_$$.txt"
  echo "probe" > "$tmp"
  gsutil ls "$bucket" >/dev/null 2>&1 || fail "cannot access bucket: $bucket"
  gsutil cp "$tmp" "$probe" >/dev/null 2>&1 || fail "cannot upload to: $probe"
  gsutil ls "$probe" >/dev/null 2>&1 || fail "upload probe missing after write: $probe"
  gsutil rm "$probe" >/dev/null 2>&1 || echo "[WARN] probe cleanup failed: $probe"
  rm -f "$tmp"
  echo "gcs upload check: ok ($GCS_PREFIX)"
else
  echo "[INFO] no --gcs-prefix provided, skip GCS check"
fi
fi

if [[ "$PREPARE_PYTHON" -eq 1 ]]; then
  echo "=== Precheck: Python Dependencies ==="
  if [[ "$PREPARE_PYTHON_FORCE" -ne 1 ]] && python_deps_ready; then
    echo "[INFO] python dependencies already ready, skip reinstall"
    echo "[OK] python dependencies prepared"
    echo "[OK] precheck passed"
    exit 0
  fi
  mkdir -p "$WORK_DIR"
  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip setuptools wheel

  if [[ ! -d "$LLF_DIR/.git" ]]; then
    git clone https://github.com/hiyouga/LLaMA-Factory.git "$LLF_DIR"
  fi

  cd "$LLF_DIR"
  python -m pip install -e .
  python -m pip install -U huggingface_hub

  HAS_GPU=0
  if check_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    HAS_GPU=1
  elif has_nvidia_pci; then
    fail "NVIDIA GPU device exists but nvidia-smi unavailable. driver/init incomplete; reboot and rerun."
  fi

  if [[ "$FORCE_TORCH_REINSTALL" -eq 1 ]]; then
    python -m pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true
  fi

  if ! python - <<'PY' >/dev/null 2>&1
import torch
print(torch.__version__)
PY
  then
    if [[ "$HAS_GPU" -eq 1 ]]; then
      echo "[INFO] GPU detected, installing CUDA torch wheels (cu121)"
      python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio
    else
      echo "[INFO] CPU-only environment, installing CPU torch wheels"
      python -m pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision torchaudio
    fi
  fi

  CUDA_AVAILABLE="$(python - <<'PY'
import torch
print("1" if torch.cuda.is_available() else "0")
PY
)"
  if [[ "$HAS_GPU" -eq 1 ]] && [[ "$CUDA_AVAILABLE" != "1" ]]; then
    echo "[WARN] GPU detected but torch cuda unavailable, reinstalling CUDA torch..."
    python -m pip uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true
    python -m pip install --index-url https://download.pytorch.org/whl/cu121 torch torchvision torchaudio
    CUDA_AVAILABLE="$(python - <<'PY'
import torch
print("1" if torch.cuda.is_available() else "0")
PY
)"
  fi

  if [[ "$HAS_GPU" -eq 1 ]] && [[ "$CUDA_AVAILABLE" != "1" ]]; then
    fail "GPU detected but torch cuda still unavailable after auto-fix"
  fi

  python - <<'PY'
import torch
print(f"[INFO] torch={torch.__version__}, cuda_available={torch.cuda.is_available()}")
PY
  echo "[OK] python dependencies prepared"
fi

echo "[OK] precheck passed"
