#!/bin/zsh
# Converts a Hugging Face Whisper fine-tune to Core ML (WhisperKit format) and installs it for lang.
# Usage: convert_model.sh <lab folder> [hf model id]      (default: erax-ai/EraX-WoW-Turbo-V1.1)
# Needs: <lab>/.venv with whisperkittools  (uv venv --python 3.11 .venv && uv pip install git+https://github.com/argmaxinc/whisperkittools)
# Takes ~20 min and ~5 GB of free disk on an M1 Pro.
set -euo pipefail
lab=${1:?lab folder}; hf=${2:-erax-ai/EraX-WoW-Turbo-V1.1}
name=${hf/\//_}
export HF_HOME="$lab/hf-cache"
mkdir -p "$lab/converted" "$lab/logs"

# The conversion happens inside whisperkittools' own tests, so don't pass --disable-default-tests.
# Some of those tests fail on fine-tunes (torch2torch decoder check, context-prefill PSNR); what matters
# is that AudioEncoder + TextDecoder .mlmodelc exist, then measure WER with run_model.sh + score.py.
"$lab/.venv/bin/whisperkit-generate-model" --model-version "$hf" --output-dir "$lab/converted/$name" \
  > "$lab/logs/convert-$name.log" 2>&1 || true
out="$lab/converted/$name/$name"
for part in MelSpectrogram AudioEncoder TextDecoder; do
  [[ -d "$out/$part.mlmodelc" ]] || { echo "Conversion failed: $part missing (see $lab/logs/convert-$name.log)"; exit 1; }
done
snap=$(ls -d "$HF_HOME"/hub/models--${hf/\//--}/snapshots/* | head -1)
cp "$snap/config.json" "$snap/generation_config.json" "$out/"
rm -f "$out"/*.mlcomputeplan.json

dest="$HOME/Library/Application Support/Lang/Models/models/local/$name"
mkdir -p "${dest:h}"
rm -rf "${dest:?}"
ditto "$out" "$dest"
touch "$dest/.download-complete"
echo "Installed: $dest"
