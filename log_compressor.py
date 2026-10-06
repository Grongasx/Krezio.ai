#!/usr/bin/env python3
"""Compress a PyTorch / Hugging Face training log into a small JSON summary.

Drops tqdm progress bars and duplicate lines, then keeps only what matters:
metrics (loss, accuracy, epoch...), gradient spikes and critical errors.
Standard library only.

    python log_compressor.py training_logs.txt            # -> training_logs.summary.json
    python log_compressor.py run.log -o out.json --spike-factor 4

Prints one line to stdout; never echoes the log itself.
"""
from __future__ import annotations

import argparse
import ast
import json
import math
import re
import statistics
import sys
from pathlib import Path

# tqdm: " 45%|████▌     | 450/1000 [00:12<00:15, 36.1it/s]" and variants.
TQDM = re.compile(r"\d{1,3}%\|.*?\|\s*\d+/\d+|\[\d+:\d+(?::\d+)?<[\d:?]+,\s*[\d.?]+\s*(?:it|s)/(?:s|it)")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# Hugging Face Trainer logs a Python dict per step: {'loss': 0.51, 'grad_norm': 3.2, 'epoch': 1.0}
HF_DICT = re.compile(r"\{[^{}]*'(?:loss|eval_loss|train_loss|grad_norm|epoch)'[^{}]*\}")
# Free-form "loss: 0.31", "Loss=0.31", "val_acc 0.93", "Epoch 3/10".
KV = re.compile(
    r"\b(?P<key>(?:train_|val_|eval_|test_)?(?:loss|acc|accuracy|f1|grad_norm|gradient_norm|lr|learning_rate|perplexity|ppl))"
    r"\s*[:=]\s*(?P<val>-?(?:\d+(?:\.\d+)?(?:e-?\d+)?|nan|inf))",
    re.IGNORECASE,
)
EPOCH = re.compile(r"\bepoch\s*[:=]?\s*(\d+(?:\.\d+)?)(?:\s*/\s*(\d+))?", re.IGNORECASE)

CRITICAL = re.compile(
    r"Traceback \(most recent call last\)|\b(?:\w+Error|\w+Exception)\b:|CUDA out of memory|OutOfMemory|"
    r"\bKilled\b|Segmentation fault|\bFATAL\b|\bCRITICAL\b|\bERROR\b|loss\s*(?:is|=|:)\s*nan|\bnan\b loss",
    re.IGNORECASE,
)
WARNING = re.compile(r"\bwarn(?:ing)?\b", re.IGNORECASE)

MAX_ERRORS = 10
MAX_SPIKES = 20
TRACEBACK_TAIL = 12


def _num(v):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f


def read_lines(path: Path) -> list[str]:
    # newline="" keeps "\r" as is: the default would turn every tqdm redraw
    # into its own line and shift all line numbers against the real file.
    with path.open(encoding="utf-8", errors="replace", newline="") as f:
        text = ANSI.sub("", f.read())
    lines: list[str] = []
    for raw in text.split("\n"):
        # tqdm redraws with \r: only the last redraw of a line is real
        # ("\r\n" line endings leave an empty last piece, so skip those).
        parts = [p for p in raw.rstrip("\r").split("\r")]
        lines.append(parts[-1].rstrip())
    if lines and lines[-1] == "":
        lines.pop()  # trailing newline
    return lines


def clean(lines: list[str]) -> tuple[list[str], list[int], int, int]:
    """Remove progress bars, blank lines and duplicates (keeps first occurrence).

    Also returns each kept line's 1-based number in the original log, so the
    summary points at the real file (`sed -n 'Np' training_logs.txt`).
    """
    seen: set[str] = set()
    out: list[str] = []
    origin: list[int] = []
    progress = dupes = 0
    for n, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        if TQDM.search(line) and not KV.search(line) and not HF_DICT.search(line):
            progress += 1
            continue
        key = re.sub(r"\d+(?:\.\d+)?", "#", line.strip()) if TQDM.search(line) else line.strip()
        if key in seen:
            dupes += 1
            continue
        seen.add(key)
        out.append(line)
        origin.append(n)
    return out, origin, progress, dupes


def extract_metrics(lines: list[str], origin: list[int]) -> list[dict]:
    points: list[dict] = []
    for i, line in enumerate(lines):
        point: dict = {}
        for m in HF_DICT.finditer(line):
            try:
                d = ast.literal_eval(m.group(0).replace("nan", "None").replace("inf", "None"))
            except (ValueError, SyntaxError):
                continue
            for k, v in d.items():
                f = _num(v) if v is not None else float("nan")
                if f is not None:
                    point[k] = f
        for m in KV.finditer(line):
            f = _num(m.group("val"))
            if f is not None:
                point.setdefault(m.group("key").lower(), f)
        e = EPOCH.search(line)
        if e:
            point.setdefault("epoch", float(e.group(1)))
            if e.group(2):
                point["epochs_total"] = float(e.group(2))
        if point:
            point["line"] = origin[i]
            points.append(point)
    return points


def gradient_spikes(points: list[dict], factor: float) -> list[dict]:
    key = next((k for k in ("grad_norm", "gradient_norm") if any(k in p for p in points)), None)
    if key is None:
        return []
    values = [p[key] for p in points if key in p and not math.isnan(p[key])]
    base = statistics.median(values) if values else 0.0
    spikes = []
    for p in points:
        v = p.get(key)
        if v is None:
            continue
        if math.isnan(v) or math.isinf(v) or (base > 0 and v > factor * base):
            spikes.append({"line": p["line"], key: v if math.isfinite(v) else str(v), "median": round(base, 6),
                           "epoch": p.get("epoch")})
    return spikes[:MAX_SPIKES]


def critical_errors(lines: list[str], origin: list[int]) -> list[dict]:
    errors: list[dict] = []
    i = 0
    while i < len(lines) and len(errors) < MAX_ERRORS:
        line = lines[i]
        if line.startswith("Traceback (most recent call last)"):
            j = i + 1
            while j < len(lines) and (lines[j].startswith((" ", "\t")) or lines[j].startswith("During handling")):
                j += 1
            end = min(j + 1, len(lines))  # the "XError: message" line
            block = lines[i:end]
            errors.append({"line": origin[i], "type": "traceback", "tail": block[-TRACEBACK_TAIL:]})
            i = end
            continue
        if CRITICAL.search(line):
            errors.append({"line": origin[i], "type": "error", "text": line.strip()[:300]})
        i += 1
    return errors


def summarize(points: list[dict]) -> dict:
    losses = [(p["line"], p.get("loss", p.get("train_loss"))) for p in points if "loss" in p or "train_loss" in p]
    losses = [(ln, v) for ln, v in losses if v is not None and math.isfinite(v)]
    last = points[-1] if points else {}
    summary: dict = {"points": len(points), "last": {k: v for k, v in last.items()}}
    if losses:
        best = min(losses, key=lambda t: t[1])
        tail = [v for _, v in losses[-5:]]
        trend = "caindo" if tail[-1] < tail[0] * 0.98 else ("subindo" if tail[-1] > tail[0] * 1.02 else "estável")
        summary.update(first_loss=losses[0][1], last_loss=losses[-1][1], best_loss=best[1], best_loss_line=best[0], trend=trend)
    if any(not math.isfinite(p.get("loss", 0.0)) for p in points):
        summary["loss_nan_or_inf"] = True
    for key in ("accuracy", "acc", "eval_accuracy", "val_acc", "f1", "eval_loss"):
        vals = [p[key] for p in points if key in p]
        if vals:
            summary[f"last_{key}"] = vals[-1]
    return summary


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("log", type=Path)
    ap.add_argument("-o", "--output", type=Path)
    ap.add_argument("--spike-factor", type=float, default=5.0, help="grad_norm > factor × median is a spike")
    args = ap.parse_args(argv)
    if not args.log.is_file():
        print(f"log_compressor: arquivo nao encontrado: {args.log}", file=sys.stderr)
        return 2

    raw = read_lines(args.log)
    lines, origin, progress, dupes = clean(raw)
    points = extract_metrics(lines, origin)
    result = {
        "source": str(args.log),
        "lines_total": len(raw),
        "lines_kept": len(lines),
        "progress_lines_removed": progress,
        "duplicates_removed": dupes,
        "warnings": sum(1 for l in lines if WARNING.search(l)),
        "metrics": summarize(points),
        "gradient_spikes": gradient_spikes(points, args.spike_factor),
        "critical_errors": critical_errors(lines, origin),
    }
    out = args.output or args.log.with_suffix(".summary.json")
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
    m = result["metrics"]
    # ASCII only: Windows consoles default to cp1252.
    print(f"{out} | linhas {len(raw)}->{len(lines)} | loss {m.get('last_loss', '-')} (melhor {m.get('best_loss', '-')}, "
          f"{m.get('trend', '-')}) | picos {len(result['gradient_spikes'])} | erros {len(result['critical_errors'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
