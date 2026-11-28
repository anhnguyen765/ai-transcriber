"""Word error rate (WER) of each model's transcripts against reference text.

Usage: python -I score.py <lab folder>
Reads <lab>/testsets/<set>/refs.jsonl and <lab>/results/<model>/<set>/*.json (whisperkit-cli --report output).
Text is compared after lowercasing, Unicode NFC, and removing punctuation, so only real word mistakes count.
"""
import json, re, sys, unicodedata
from pathlib import Path

import jiwer


DIGITS = "không một hai ba bốn năm sáu bảy tám chín".split()


def read_below_1000(n: int, full: bool) -> str:
    """Vietnamese words for 0-999; full=True keeps "không trăm" / "linh" (used after a higher group)."""
    hundreds, tens, ones = n // 100, n // 10 % 10, n % 10
    words = []
    if hundreds or full:
        words += [DIGITS[hundreds], "trăm"]
    if tens == 0:
        if ones and words:
            words.append("linh")
    elif tens == 1:
        words.append("mười")
    else:
        words += [DIGITS[tens], "mươi"]
    if ones:
        if ones == 5 and tens:
            words.append("lăm")
        elif ones == 1 and tens > 1:
            words.append("mốt")
        elif ones == 4 and tens > 1:
            words.append("tư")
        else:
            words.append(DIGITS[ones])
    return " ".join(words) or "không"


def read_number(digits: str) -> str:
    n = int(digits)
    if n == 0:
        return "không"
    groups, units = [], ["", "nghìn", "triệu", "tỷ"]
    i = 0
    while n and i < len(units):
        groups.append((n % 1000, units[i]))
        n //= 1000
        i += 1
    out = []
    for k, (g, unit) in enumerate(reversed(groups)):
        if g:
            out += [read_below_1000(g, full=k > 0), unit]
    return " ".join(w for w in out if w)


def norm(text: str) -> str:
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"(?<=\d)[.,](?=\d{3}\b)", "", text)   # 800.000 -> 800000
    text = re.sub(r"\d+", lambda m: " " + read_number(m.group()) + " ", text)
    text = text.replace("ngàn", "nghìn").replace(" lẻ ", " linh ")
    text = re.sub(r"[^\w\s]", " ", text)  # \w keeps Vietnamese letters with tones
    return re.sub(r"\s+", " ", text).strip()


def hyp_text(report: Path) -> str:
    data = json.loads(report.read_text(encoding="utf-8"))
    if isinstance(data, list):
        data = data[0]
    return data.get("text") or " ".join(s.get("text", "") for s in data.get("segments", []))


def main(lab: Path):
    rows = []
    for model_dir in sorted((lab / "results").iterdir()):
        for set_dir in sorted(p for p in model_dir.iterdir() if p.is_dir()):
            refs = [json.loads(l) for l in (lab / "testsets" / set_dir.name / "refs.jsonl").read_text(encoding="utf-8").splitlines()]
            pairs, missing = [], 0
            for r in refs:
                rep = next(set_dir.glob(f"{r['id']}*.json"), None)
                if rep is None:
                    missing += 1
                    continue
                pairs.append((norm(r["text"]), norm(hyp_text(rep))))
            if not pairs:
                continue
            wer = jiwer.wer([p[0] for p in pairs], [p[1] for p in pairs])
            cer = jiwer.cer([p[0] for p in pairs], [p[1] for p in pairs])
            rows.append((model_dir.name, set_dir.name, wer, cer, len(pairs), missing))
    print(f"{'model':48} {'set':8} {'WER':>7} {'CER':>7}  n")
    for m, s, w, c, n, miss in rows:
        print(f"{m:48} {s:8} {w*100:6.2f}% {c*100:6.2f}%  {n}" + (f" ({miss} missing)" if miss else ""))


if __name__ == "__main__":
    main(Path(sys.argv[1]))
