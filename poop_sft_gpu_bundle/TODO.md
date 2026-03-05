# poop_sft scripts rebuild TODO

## Scope
- Source scripts analyzed:
- `scripts/run_train_job.sh` (1288 lines)
- `scripts/precheck_env.sh` (449 lines)
- `scripts/chat_with_model.sh` (346 lines)
- `scripts/export_to_gcs.sh` (113 lines)
- `scripts/monitor_hf_eta.sh` (117 lines)

## Current architecture findings
- `run_train_job.sh` mixes 7 responsibilities in one file:
- CLI parsing
- interactive wizard
- workspace/global config persistence
- precheck orchestration
- data merge/shuffle/validation
- training config generation (YAML)
- training execution + monitor + GCS sync loop
- Workspace resolution logic is duplicated in all scripts.
- `precheck_env.sh` was previously called twice; now collapsed to a single pass in run script.
- Dependency checks are done by import probing, but install side effects still live inside precheck.
- Data processing in run script currently does:
- file concat
- newline normalization
- optional JSONL shuffle
- but does not provide structured stats (length distribution/source split) before parameter defaults.
- Resume logic is split between interactive checkpoint picker and later auto-resume detection from `output_poop_sft`.
- GCS sync logic is embedded in run script background loop; no reusable sync module.
- Chat script has improved adapter/model auto-discovery, but model-choice UX and generation stop rules are still separate concerns from train metadata.

## Coupling and pain points
- High coupling between prompt flow and execution flow in `run_train_job.sh`.
- Shared constants/path normalization copied across scripts.
- Repeated precheck output reduces clarity.
- Data strategy (merge/shuffle/split) and training strategy (lr/epochs/lora params) are not modular.
- Export script still includes fallback legacy dataset copy behavior; should prefer explicit run metadata artifacts.

## Rebuild target structure
- `scripts/run_train_job.sh`:
- only CLI + interactive orchestration + module calls
- `scripts/lib/common.sh`:
- logging, error helpers, command checks, path normalization, workspace persistence
- `scripts/lib/workspace.sh`:
- workspace/global config read-write, env export (`TMPDIR`, `HF_HOME`, caches)
- `scripts/lib/precheck.sh`:
- system checks, driver checks, gcs permission probe, python dependency status
- `scripts/lib/deps.sh`:
- venv creation, llama-factory clone/update, pip install policy, torch install/fix
- `scripts/lib/data.sh`:
- dataset discovery, selected/all modes, jsonl validation, merge, shuffle, source tagging, split helpers
- `scripts/lib/params.sh`:
- stats-driven default suggestion for `lora_r/lora_alpha/lr/cutoff/epochs|max_steps`
- `scripts/lib/config.sh`:
- write YAML + write `last_run.env`
- `scripts/lib/train.sh`:
- launch, resume handling, monitor process lifecycle
- `scripts/lib/sync.sh`:
- step-based GCS sync loop + final sync

## TODO (execution order)
- [x] T1. Create `scripts/lib/` and move shared workspace/path logic into `common.sh` + `workspace.sh`.
- [ ] T2. Refactor `precheck_env.sh` to call `lib/precheck.sh` and `lib/deps.sh` with explicit modes:
- [ ] `--check-only`
- [ ] `--prepare-deps`
- [ ] `--fix-driver`
- [ ] T3. Refactor `run_train_job.sh` into staged pipeline:
- [ ] Stage A: parse args + interactive selections
- [ ] Stage B: precheck summary + confirm continue
- [ ] Stage C: data plan + stats print
- [ ] Stage D: param suggestion + user overrides
- [ ] Stage E: train launch + monitor + sync
- [ ] T4. Move dataset logic into `lib/data.sh` with functions:
- [x] `discover_jsonl_files` (implemented as `pt_collect_data_files`)
- [x] `validate_jsonl_schema` (implemented via normalize step: parse/clean/skip invalid rows)
- [x] `merge_jsonl_files`
- [x] `shuffle_jsonl_rows`
- [x] `compute_dataset_stats` (rows/json_errors/length quantiles)
- [ ] T5. Add stats-driven defaults in `lib/params.sh`:
- [x] prompt for `lora_r`, `lora_alpha`, `learning_rate`, `num_train_epochs`
- [x] default values derived from model size + data size + hardware
- [ ] T6. Split YAML rendering to `lib/config.sh`; keep one output contract:
- [ ] YAML path
- [ ] metadata env path
- [ ] resolved effective params
- [ ] T7. Move GCS auto-sync loop into `lib/sync.sh` and make disable path explicit (`0` or `off`).
- [ ] T8. Make `monitor_hf_eta.sh` read from `last_run.env` by default if output dir omitted.
- [ ] T9. Update `export_to_gcs.sh` to export only run-linked artifacts from metadata (remove broad legacy fallback copies).
- [ ] T10. Keep backward compatibility for old CLI flags used in existing docs.
- [ ] T11. Add `scripts/tests/smoke_local.sh` with dry-run checks:
- [ ] parse args
- [ ] single precheck
- [ ] data merge/shuffle
- [ ] yaml generation
- [ ] no train launch
- [ ] T12. Update README flowchart and command examples to match new module layout.

## Immediate quick wins before full rebuild
- [x] Q1. Remove duplicate precheck panel output in `run_train_job.sh` (combine phase messages).
- [x] Q2. Print model menu labels with model IDs in one line to avoid numeric ambiguity.
- [x] Q3. Print explicit hint for GCS sync disable at prompt (`0=disable`, `off=disable`).
- [x] Q4. Print selected mode/model/data summary before dependency prepare starts.

## Acceptance criteria
- One command can run fully interactive with sensible defaults.
- Precheck summary appears once per run (unless explicit retry/fix requested).
- Re-run on same workspace does not reinstall dependencies unless forced.
- Resume/train-new flow is unambiguous and checkpoint discovery is deterministic.
- Data plan and effective training params are visible before training starts.
- GCS sync behavior can be enabled/disabled explicitly and is reflected in logs.
# Backlog

## UI/Interaction Refactor (for unified manager panel)

### Source: live CPU/GPU test feedback (2026-02-24)

1. Current flow feels confusing:
- `Continue training now` appears before user completes model/data decisions.
- Multiple prompts create context switching.

2. Resume mode UX:
- If user selects `continue existing training` but no checkpoint exists, current behavior falls back abruptly.
- Need explicit "no checkpoint found" + options:
  - back to previous menu
  - switch to train-new
  - cancel

3. Base model selection UX simplification:
- User mental model should be only:
  - choose existing base model
  - pull a new base model
- "download to local store" should be implementation detail, not a separate mental mode.

4. Future unified manager panel requirements:
- All menus must support "Back" / "Cancel".
- Central entry with concise options.
- Job running state shown in one dashboard view.
- Detailed logs should be optional (expand/view), not default flood.

5. GCS prompt clarity:
- Keep support for explicit disable (`off/none/0`).
- Keep explicit example format in prompt.

6. Navigation consistency requirement:
- Any nested selection must have a safe return path to previous level.

## Notes
- These are recorded as product/UX requirements for next major refactor.
- Not all items are implemented in current script generation flow.

## New UX requirement (2026-02-24)
- For every interactive selection step, provide an explicit "Back to previous menu" option.
- Applies to all nested prompts, including checkpoint picker/model selection/data selection/parameter inputs.
- Current blocker example: checkpoint selection only supports index/manual, no back path.

## Progress update (2026-02-24, latest)
- Implemented in `scripts/run_train_job.sh`:
- training mode -> checkpoint picker now supports `b=back`
- no-checkpoint case now asks: back to mode or switch to train-new
- base model source menu supports `b=back`
- local base model picker supports `b=back`
- data selection step retries safely instead of exiting on invalid/empty flow
- Implemented in `scripts/lib/interactive.sh`:
- all direct `read -r -p` replaced with `pt_read_prompt` for control-char cleanup
- model picker supports `b=back` and returns `__BACK__` to caller
- dataset path/file picker supports `b=back`, including nested custom-path input

## Remaining (next pass)
- Parameter prompts (`lora_r/lora_alpha/lr/epochs/sync_steps`) still need explicit `b=back` chain.
- Long-term manager panel remains backlog; current work is CLI interaction hardening.
