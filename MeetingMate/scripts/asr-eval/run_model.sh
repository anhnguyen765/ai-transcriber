#!/bin/zsh
# Transcribes every test set with one CoreML Whisper model, using the same decoding settings as the app.
# Usage: run_model.sh <lab folder> <name> <model folder>
set -euo pipefail
lab=$1; name=$2; model=$3
for set in "$lab"/testsets/*(/); do
  out="$lab/results/$name/${set:t}"
  mkdir -p "$out"
  echo "== $name / ${set:t}"
  whisperkit-cli transcribe --model-path "$model" --audio-folder "$set/audio" \
    --language vi --use-prefill-prompt --skip-special-tokens --temperature-fallback-count 5 \
    --report --report-path "$out" > "$out.log" 2>&1
done
