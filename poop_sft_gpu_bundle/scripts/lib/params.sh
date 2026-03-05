#!/usr/bin/env bash

pt_suggest_defaults() {
  local model_name="$1"
  local rows="$2"
  local has_gpu="$3"

  local model_lc
  model_lc="$(echo "$model_name" | tr '[:upper:]' '[:lower:]')"

  local def_epochs cutoff batch grad_acc lr save_steps lora_r lora_alpha

  if [[ "$has_gpu" -eq 1 ]]; then
    cutoff=512
    save_steps=30
    if [[ "$model_lc" == *"7b"* ]]; then
      batch=1
      grad_acc=8
      lr="1.5e-4"
      lora_r=32
      lora_alpha=64
    elif [[ "$model_lc" == *"3b"* ]]; then
      batch=2
      grad_acc=8
      lr="1.5e-4"
      lora_r=16
      lora_alpha=32
    else
      batch=2
      grad_acc=8
      lr="1e-4"
      lora_r=16
      lora_alpha=32
    fi
  else
    cutoff=256
    batch=1
    grad_acc=4
    lr="8e-5"
    save_steps=50
    if [[ "$model_lc" == *"7b"* ]]; then
      lora_r=16
      lora_alpha=32
    else
      lora_r=8
      lora_alpha=16
    fi
  fi

  if [[ "$rows" =~ ^[0-9]+$ ]] && (( rows < 800 )); then
    def_epochs=5
  else
    def_epochs=3
  fi

  echo "DEF_EPOCHS=$def_epochs"
  echo "DEF_CUTOFF_LEN=$cutoff"
  echo "DEF_BATCH=$batch"
  echo "DEF_GRAD_ACC=$grad_acc"
  echo "DEF_LR=$lr"
  echo "DEF_SAVE_STEPS=$save_steps"
  echo "DEF_LORA_R=$lora_r"
  echo "DEF_LORA_ALPHA=$lora_alpha"
}
