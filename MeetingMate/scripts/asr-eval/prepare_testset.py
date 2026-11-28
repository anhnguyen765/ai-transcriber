"""Builds small Vietnamese test sets (16 kHz mono WAV + reference text) for comparing Whisper models.

Usage: python -I prepare_testset.py <lab folder> [--n 100]
Expects (inside <lab folder>/downloads):
  fleurs/test.tsv + fleurs/test.tar.gz   from google/fleurs  data/vi_vn/
  vivos/vivos.tar.gz                     from AILAB-VNUHCM/vivos data/
Writes <lab folder>/testsets/<name>/audio/*.wav and refs.jsonl
"""
import argparse, csv, json, random, tarfile, unicodedata
from pathlib import Path

import librosa
import soundfile as sf


def save(out_dir: Path, items, n: int, seed: int = 7):
    random.Random(seed).shuffle(items)
    items = items[:n]
    (out_dir / "audio").mkdir(parents=True, exist_ok=True)
    with open(out_dir / "refs.jsonl", "w", encoding="utf-8") as f:
        for uid, load, text in items:
            audio, _ = librosa.load(load(), sr=16_000, mono=True)
            sf.write(out_dir / "audio" / f"{uid}.wav", audio, 16_000)
            f.write(json.dumps({"id": uid, "text": unicodedata.normalize("NFC", text)}, ensure_ascii=False) + "\n")
    print(out_dir.name, len(items), "utterances")


def fleurs(lab: Path, n: int):
    dl = lab / "downloads/fleurs"
    refs = {}
    with open(dl / "test.tsv", encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
            refs[row[1]] = row[2]  # file name -> raw transcription (with case + punctuation)
    tmp = lab / "extracted/fleurs"
    tmp.mkdir(parents=True, exist_ok=True)
    with tarfile.open(dl / "test.tar.gz") as tar:
        members = [m for m in tar.getmembers() if m.isfile() and Path(m.name).name in refs]
        tar.extractall(tmp, members=members, filter="data")
    items = [(Path(m.name).stem, (lambda p=tmp / m.name: p), refs[Path(m.name).name]) for m in members]
    save(lab / "testsets/fleurs", items, n)


def vivos(lab: Path, n: int):
    tmp = lab / "extracted/vivos"
    tmp.mkdir(parents=True, exist_ok=True)
    with tarfile.open(lab / "downloads/vivos/vivos.tar.gz") as tar:
        members = [m for m in tar.getmembers() if m.isfile() and "/test/" in m.name]
        tar.extractall(tmp, members=members, filter="data")
    prompts = next(tmp.rglob("test/prompts.txt"))
    refs = dict(line.strip().split(" ", 1) for line in prompts.read_text(encoding="utf-8").splitlines() if " " in line)
    wavs = {p.stem: p for p in tmp.rglob("test/waves/*/*.wav")}
    items = [(uid, (lambda p=wavs[uid]: p), text) for uid, text in refs.items() if uid in wavs]
    save(lab / "testsets/vivos", items, n)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("lab", type=Path)
    ap.add_argument("--n", type=int, default=100)
    a = ap.parse_args()
    fleurs(a.lab, a.n)
    vivos(a.lab, a.n)
