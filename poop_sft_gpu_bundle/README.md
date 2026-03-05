# poopTrain

## 目标
这个 pack 用于在 GPU 机器上快速完成中文 LLM 微调（SFT）流程，重点是：
- 先做训练前检查，避免 GPU 空转烧钱
- 一键启动训练并实时查看进度/ETA
- 训练结束后快速导出到 GCS，并可立即关机省费用

## 当前状态
- 数据集已就绪：`data/instructions_gpt_94_v2.jsonl`（JSONL，`instruction/input/output`）
- 风格锚点语料：`instructionset/original.txt`
- 训练与导出脚本已拆分为 3 段主流程（见下方）

## 三段式脚本（推荐）
1. 训练前检查（可选失败即关机）
```bash
./scripts/precheck_env.sh --gcs-prefix gs://<your-bucket>/<path> --shutdown-on-fail
```
说明：
- 脚本默认启用自动修复（`apt-get` 可用时）：会尝试安装缺失的 `python3-venv/python3.x-venv` 与 `google-cloud-cli(gsutil)`。

2. 启动训练（含模型拉取 + 实时 ETA）
```bash
./scripts/run_train_job.sh
```
说明：
- 无参数运行即进入交互式菜单，所有问题都可直接回车使用默认值。
- 首次会询问 workspace 名称/路径，回车默认 `poopworkspace`（位于 bundle 同级目录）；选择会持久化到 `~/.config/pooptrain/workspace.env`。
- 可选默认配置文件：`<workspace>/train_config.env`（模板见 `train_config.example.env`）。
- 可通过参数/配置覆盖关键训练项：`--num-train-epochs`、`--max-steps`（二选一）、`--val-size`、`--seed`、`--cutoff-len`、`--learning-rate`、`--batch`、`--grad-acc`、`--save-steps`、`--eval-steps`。
- 脚本会自动检测是否有 GPU。
- GPU 训练会自动开启混精：优先 `bf16`，否则回退 `fp16`。
- 若检测到 GPU 但 `torch.cuda_available=False`，会自动尝试修复 CUDA torch；修复失败会在开跑前中止。
- CPU 机器：自动安装 CPU 版 PyTorch（不安装 CUDA）。
- GPU 机器：自动安装 CUDA 版 PyTorch（cu121）。
- 脚本启动时会先自动跑 `precheck_env.sh`，依赖缺失才安装；已就绪会跳过重复安装。
- 下载临时目录、HF/torch/pip 缓存会落到 `<workspace>/`，避免占用系统 `/tmp`。
- 默认开启断点续训（自动寻找 `<workspace>/output_poop_sft/checkpoint-*` 最新步数）。
- HF 基底模型会统一下载/复用到 `<workspace>/base_models/`，便于复用与清理。
- 默认 `--data-mode all`：自动合并 `data/` 目录下所有 `.jsonl` 参与训练。
- 若只训练单个文件：`--data-mode single --data-file data/xxx.jsonl`
- 训练前会打印“最终生效参数摘要”，并在 `<workspace>/last_run.env` 记录关键参数，便于复现与导出。

3. 导出成果到 GCS（可选导出成功后关机）
```bash
./scripts/export_to_gcs.sh gs://<your-bucket>/<path> --shutdown
```

## 真后台服务（systemd）
如果你不想让训练绑定 SSH 会话，可用 `systemd` 用户服务启动：
```bash
./scripts/service_manager.sh start \
  --confirm \
  --run-name qwen25_7b_r01 \
  --workspace-dir ~/pooptrain/poopworkspace \
  --model Qwen/Qwen2.5-7B \
  --gcs-prefix gs://<bucket>/exports/<run-name>
```

常用命令：
```bash
./scripts/service_manager.sh list
./scripts/service_manager.sh status qwen25_7b_r01
./scripts/service_manager.sh logs qwen25_7b_r01 --follow
./scripts/service_manager.sh stop qwen25_7b_r01
./scripts/service_manager.sh dashboard --interval 3
```

说明：
- 这是“真正后台服务”，不是 `nohup/tmux/setsid`。
- `start` 会强制使用非交互训练：`--no-interactive --yes`。
- 为避免误触，`start` 必须显式加 `--confirm`；默认空配置启动被拦截。
- `dashboard` 是常驻刷新状态面板，按 `q` 退出。
- 如果提示无法访问 `systemctl --user`，先在机器上启用用户 lingering（一次性）：
```bash
sudo loginctl enable-linger "$USER"
```

## 统一菜单入口（TUI）
```bash
./pooptrain.sh
```
- 提供菜单操作：环境检查、启动训练（systemd 后台）、管理运行任务、查看最近 run、同步到 GCS、清理。
- 所有步骤可返回/取消，训练前有最终确认，避免误启动。

## GCS 路径命名建议
- 推荐格式：`gs://<bucket>/exports/<region>-<model>-<date>-<runid>`
- 示例：`gs://your-bucket/exports/us-qwen25-7b-20260224-r01`
- 说明：统一命名后，便于按地区/模型/日期筛选与清理历史训练产物。

## 关键辅助脚本
- `scripts/monitor_hf_eta.sh`：独立监控训练状态和剩余时间
- `scripts/chat_with_model.sh`：交互式体验底模+LoRA，终端问答
- `scripts/oneclick_train_workflow.sh`：交互式整合版（仍可用）
- `scripts/build_dataset_with_api.py`：数据生成脚本（Gemini/OpenAI 兼容接口）

## 训练后体验模型
```bash
./scripts/chat_with_model.sh
```
交互命令：
- 输入 `/clear` 清空对话历史
- 输入 `/exit` 退出
说明：
- 会优先导出本次训练实际使用的数据文件（来自 `<workspace>/last_run.env` 的 `LAST_DATA_FILE`）以便复现。
- 不传参数时，脚本会自动扫描可用 LoRA 目录并让你选择。
- 底模会从所选适配器的 `adapter_config.json` 自动读取。

## 运行建议（省钱版）
- 先跑 `precheck_env.sh`，确认 GCS 可写再训练
- 训练中保持监控 ETA
- 训练完成后立即导出并关机

## 关于 Codex 协作
你可在 GPU 机器上继续引入 Codex 来做：
- 训练参数调优（batch、max_steps、lora_target 等）
- 自动化导出/关机策略增强
- 日志失败定位与恢复脚本补强

建议把本目录整体上传/解压后直接在目录内执行脚本。
