# Vietnamese speech-to-text: compare Whisper models

Tools to measure word error rate (WER) of Core ML Whisper models on Vietnamese and to install a
Vietnamese fine-tune for lang. Everything heavy (venv, datasets, converted models) lives in a "lab"
folder outside the repo.

```bash
lab=~/asr-lab
uv venv --python 3.11 $lab/.venv
uv pip install --python $lab/.venv "git+https://github.com/argmaxinc/whisperkittools" soundfile jiwer librosa
brew install whisperkit-cli
```

1. Test sets: download `data/vi_vn/test.tsv` + `data/vi_vn/audio/test.tar.gz` from
   [google/fleurs](https://huggingface.co/datasets/google/fleurs) (CC BY 4.0) into `$lab/downloads/fleurs`, and
   `data/vivos.tar.gz` from [AILAB-VNUHCM/vivos](https://huggingface.co/datasets/AILAB-VNUHCM/vivos)
   (CC BY-NC-SA 4.0) into `$lab/downloads/vivos`, then
   `$lab/.venv/bin/python -I prepare_testset.py $lab --n 100`.
2. Convert + install a fine-tune: `./convert_model.sh $lab erax-ai/EraX-WoW-Turbo-V1.1`.
3. Transcribe: `./run_model.sh $lab <name> <model folder>` (same decoding settings as the app).
4. Score: `$lab/.venv/bin/python -I score.py $lab` (lowercase, no punctuation, numbers read out as words).

Your own meetings are the test that matters most: put `<id>.wav` files in `$lab/testsets/meetings/audio`
(`afconvert -f WAVE -d LEI16@16000 -c 1 mic.m4a <id>.wav`) and hand-corrected text in
`$lab/testsets/meetings/refs.jsonl` (`{"id": "...", "text": "..."}` per line). 10–30 minutes is enough.

Note: the app sets `firstTokenLogProbThreshold = nil` for the EraX model. With WhisperKit's default (-1.5)
it returned empty transcripts, because fine-tunes are less sure of their first timestamp token.

## Results (2026-11-28, 100 utterances each, M1 Pro)

| Model | FLEURS WER | VIVOS WER |
|---|---|---|
| openai large-v3 turbo (Argmax) | 9.84% | 9.24% |
| EraX-WoW-Turbo V1.1 (converted here) | **7.43%** | **6.29%** |

`suzii/vi-whisper-large-v3-turbo` failed conversion (decoder PSNR 28.8 < 35) and was trained on FLEURS.
