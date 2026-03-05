> ⚠️ **Work in progress — currently archived.**  
> No active development at the moment; the repo is kept here for reference.

## What is this?

A one-click training toolkit for **Supervised Fine-Tuning (SFT) of Chinese LLMs**, designed to run on short-lived cloud VMs (e.g. GCP) — with or without a GPU.

The core motivation: cloud VMs are billed by the second — every minute of idle time costs money.  
This project provides a self-contained bundle of shell scripts that lets you:

1. **Pre-check** the environment and abort early if anything is wrong
2. **Launch training** with a single command (or interactive TUI menu)
3. **Export the result** to GCS and optionally shut down the VM — all without manual babysitting

> **CPU and GPU are both supported.** The scripts automatically detect whether a GPU is present and adjust PyTorch installation and training precision accordingly.  
> CPU-only training is slower but fully functional — great for a dry run before spending money on a GPU VM.

## 💡 First-time tip — dry run on a cheap CPU VPS first

If this is your first time using this toolkit, it is strongly recommended to:

1. Spin up a **cheap CPU-only VPS** (any small Linux VM will do — no GPU needed)
2. Run through the full workflow once to make sure everything works end-to-end
3. Then move to a GCP GPU VM for real training

This is exactly how the author validated the scripts before using GCP.  
On a CPU machine the scripts install the CPU-only PyTorch build, so there are no CUDA surprises.

---

## Repository layout

```
Cool-LLM/
└── poop_sft_gpu_bundle/          # Main bundle — copy this to your VM
    ├── pooptrain.sh              # ★ Main entry point (TUI menu)
    ├── train_config.example.env  # Config template — copy to workspace/train_config.env
    ├── data/                     # Training datasets (JSONL)
    │   ├── instructions_gpt_94_v2.jsonl
    │   ├── generated_api.jsonl
    │   ├── generated_gemini_good.jsonl
    │   ├── identity.jsonl
    │   └── reverse_gemini.jsonl
    └── scripts/
        ├── precheck_env.sh       # Step 1 — environment & dependency check
        ├── run_train_job.sh      # Step 2 — pull model + run SFT training
        ├── export_to_gcs.sh      # Step 3 — upload checkpoint to GCS
        ├── service_manager.sh    # Manage training as a systemd user service
        ├── monitor_hf_eta.sh     # Standalone training progress / ETA monitor
        ├── chat_with_model.sh    # Interactive terminal chat with base + LoRA
        ├── clean_workspace.sh    # Clean up workspace files / caches
        └── lib/                  # Shared helper libraries
            ├── common.sh         # Logging, colors, prompt helpers
            ├── workspace.sh      # Workspace path resolution
            ├── interactive.sh     # TUI / menu helpers
            ├── data.sh           # Dataset discovery & merging
            └── params.sh         # Training parameter parsing & defaults
```

## Script overview

| Script | Role |
|---|---|
| `pooptrain.sh` | TUI menu — the single entry point for all operations |
| `scripts/precheck_env.sh` | Checks Python venv, CUDA, gsutil, GPU availability; auto-repairs where possible; can shut down on failure |
| `scripts/run_train_job.sh` | Downloads the base model (HuggingFace), sets up LLaMA-Factory, starts SFT training with resume support |
| `scripts/export_to_gcs.sh` | Uploads the trained checkpoint to a GCS bucket; optionally shuts down the VM afterwards |
| `scripts/service_manager.sh` | Wraps training as a real **systemd user service** (not tmux/nohup) — start / stop / logs / dashboard |
| `scripts/monitor_hf_eta.sh` | Standalone watcher that reads trainer state and prints estimated time remaining |
| `scripts/chat_with_model.sh` | Load base model + LoRA adapter and chat interactively in the terminal |
| `scripts/clean_workspace.sh` | Remove checkpoints, caches, or the full workspace to free disk space |

## Usage

### Part 1 — GCP setup (one-time)

1. **Create a GCS bucket** in the GCP console
2. **Create a VM** — GPU VM for real training, or a CPU-only VM for a first dry run
3. **Grant the VM access to GCS** — the simplest approach is to give the VM's service account the **"Storage Admin"** role (or enable *all Cloud APIs* access scope when creating the VM).  
   > The author used "Allow full access to all Cloud APIs" to keep things simple.
4. **Upload the bundle folder to your GCS bucket**

### Part 2 — SSH operations

Once you log into the ssh:

```bash
# Check GPU availability (optional, the script works for CPU-only too)
nvidia-smi

mkdir -p ~/pooptrain && cd ~/pooptrain
gsutil -m cp -r gs://<your-bucket>/exports/<run-name> . #the period sign . in the end is important
cd ~/pooptrain/poop_sft_gpu_bundle && chmod +x scripts/*.sh

# Start training — pass model and GCS export path directly
./scripts/run_train_job.sh --model Qwen/Qwen2.5-7B-Instruct --gcs-prefix gs://<your-bucket>/exports/<run-name>

# Chat with the trained model interactively
./scripts/chat_with_model.sh

# Export the checkpoint to GCS
# (uncomment the chmod line if needed on a fresh VM)
cd ~/pooptrain/poop_sft_gpu_bundle && chmod +x scripts/export_to_gcs.sh
./scripts/export_to_gcs.sh gs://<your-bucket>/exports/<run-name> runtime/output_poop_sft
```

## Acknowledgements

- **GCP $300 free trial credit** — made all the GPU experiments possible
- **GitHub Copilot (Student Pack)** - helped manage github repo
- **ChatGPT Codex** — built the scripts with less hardware resource consumption.
- **Google AI Studio (free tier)** - Many thanks to google again.   

---

*For Chinese documentation see [`poop_sft_gpu_bundle/README.md`](poop_sft_gpu_bundle/README.md).*
