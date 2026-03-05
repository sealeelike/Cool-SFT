#!/usr/bin/env bash

pt_abs_path() {
  local base_dir="$1"
  local p="$2"
  if [[ "$p" = /* ]]; then
    echo "$p"
  else
    echo "$base_dir/$p"
  fi
}

pt_collect_data_files() {
  local data_mode="$1"
  local data_file="$2"
  local base_dir="$3"
  local -a files=()

  case "$data_mode" in
    selected)
      [[ -f "$data_file" ]] || { echo "[ERROR] selected file list missing: $data_file" >&2; return 2; }
      mapfile -t files < "$data_file"
      ;;
    all)
      if [[ -d "$data_file" ]]; then
        mapfile -t files < <(find "$data_file" -type f -name '*.jsonl' | sort)
      else
        mapfile -t files < <(find "$base_dir/data" -type f -name '*.jsonl' | sort)
      fi
      ;;
    single)
      files+=("$(pt_abs_path "$base_dir" "$data_file")")
      ;;
    *)
      echo "[ERROR] unsupported data_mode: $data_mode" >&2
      return 2
      ;;
  esac

  [[ "${#files[@]}" -gt 0 ]] || { echo "[ERROR] no jsonl found for data_mode=$data_mode" >&2; return 2; }
  printf '%s\n' "${files[@]}"
}

pt_merge_jsonl_files() {
  local merged_file="$1"
  shift
  local -a files=("$@")

  : > "$merged_file"
  local f
  for f in "${files[@]}"; do
    cat "$f" >> "$merged_file"
    printf '\n' >> "$merged_file"
  done
}

pt_normalize_jsonl_file() {
  local src="$1"
  local dst="$2"
  local python_bin="$3"

  DATA_FILE_ENV="$src" OUT_FILE_ENV="$dst" "$python_bin" - <<'PY'
import json
import os

src = os.environ["DATA_FILE_ENV"]
dst = os.environ["OUT_FILE_ENV"]
rows = 0
skipped = 0

with open(src, "r", encoding="utf-8") as fin, open(dst, "w", encoding="utf-8") as fout:
    for i, line in enumerate(fin, 1):
        s = line.strip()
        if not s:
            continue
        try:
            obj = json.loads(s)
        except Exception:
            skipped += 1
            continue
        if not isinstance(obj, dict):
            skipped += 1
            continue

        ins = obj.get("instruction", "")
        inp = obj.get("input", "")
        out = obj.get("output", "")
        if ins is None: ins = ""
        if inp is None: inp = ""
        if out is None: out = ""
        ins = str(ins)
        inp = str(inp)
        out = str(out)
        if not ins.strip() and not out.strip():
            skipped += 1
            continue

        norm = {
            "instruction": ins,
            "input": inp,
            "output": out,
        }
        fout.write(json.dumps(norm, ensure_ascii=False) + "\n")
        rows += 1

print(f"normalized_rows={rows}")
print(f"normalized_skipped={skipped}")
PY
}

pt_shuffle_jsonl_file() {
  local src="$1"
  local dst="$2"
  local seed="$3"
  local python_bin="$4"

  DATA_FILE_ENV="$src" SHUFFLED_DATA_FILE_ENV="$dst" SEED_ENV="$seed" "$python_bin" - <<'PY'
import json
import os
import random

src = os.environ["DATA_FILE_ENV"]
dst = os.environ["SHUFFLED_DATA_FILE_ENV"]
seed = int(os.environ.get("SEED_ENV", "42"))

rows = []
with open(src, "r", encoding="utf-8") as f:
    for line in f:
        s = line.strip()
        if not s:
            continue
        rows.append(json.loads(s))

rng = random.Random(seed)
rng.shuffle(rows)

with open(dst, "w", encoding="utf-8") as f:
    for row in rows:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")

print(f"shuffled_rows={len(rows)}")
PY
}

pt_count_nonempty_rows() {
  local file="$1"
  awk 'NF{c++} END{print c+0}' "$file"
}

pt_compute_dataset_stats() {
  local file="$1"
  local python_bin="$2"

  DATA_FILE_ENV="$file" "$python_bin" - <<'PY'
import json
import os

p = os.environ["DATA_FILE_ENV"]
lengths = []
rows = 0
errors = 0
with open(p, "r", encoding="utf-8") as f:
    for i, line in enumerate(f, 1):
        s = line.strip()
        if not s:
            continue
        try:
            obj = json.loads(s)
        except Exception:
            errors += 1
            continue
        ins = str(obj.get("instruction", ""))
        inp = str(obj.get("input", ""))
        out = str(obj.get("output", ""))
        lengths.append(len(ins) + len(inp) + len(out))
        rows += 1

if rows == 0:
    print("rows=0")
    print("json_errors=%d" % errors)
    print("avg_chars=0")
    print("p95_chars=0")
    print("max_chars=0")
    raise SystemExit(0)

lengths.sort()
idx95 = int(round((len(lengths)-1) * 0.95))
print(f"rows={rows}")
print(f"json_errors={errors}")
print(f"avg_chars={sum(lengths)//len(lengths)}")
print(f"p95_chars={lengths[idx95]}")
print(f"max_chars={lengths[-1]}")
PY
}
