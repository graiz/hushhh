#!/usr/bin/env python3
"""Compares speech engines on your own dictations.

Hushhh keeps recent dictations when `keepRecentRecordings` is on (docs/DEVELOPMENT.md).
This script turns them into a test set: you write down what you really said, and every
engine is scored by word error rate against that.

    scripts/benchmark.py draft     # add new recordings to references.tsv, pre-filled with
                                   # what Hushhh inserted; correct the text, mark rows "ok"
    scripts/benchmark.py run       # transcribe the "ok" rows with each engine and score them
    scripts/benchmark.py run --engines qvac,parakeet --show   # also list each mismatch

Engines: inserted (what Hushhh produced live), qvac, whisper (Hushhh's Whisper model,
or --whisper-model), apple (macOS 26 SpeechTranscriber) and parakeet (Parakeet TDT 0.6B v2
through transcribe.cpp; downloads the 10 MB library and the 731 MB model on first use).
Each whole recording is transcribed in one pass; results are cached per engine, so
re-runs only transcribe new recordings. Needs a Debug build (`make debug`).
"""

import argparse
import csv
import hashlib
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "build/DerivedData/Build/Products/Debug/Hushhh.app/Contents/MacOS/Hushhh"
RECORDINGS = Path.home() / "Library/Logs/Hushhh/Recordings"
BENCH = Path.home() / "Library/Logs/Hushhh/Benchmark"
REFERENCES = BENCH / "references.tsv"
TOOLS = Path.home() / "Library/Caches/Hushhh/Benchmark"

FRAMEWORK_URL = "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.1/TranscribeCpp.xcframework.zip"
FRAMEWORK_SHA = "fb5646e564036a6c49659e3efcf72eb567af20da31b8569045c9a08181d35126"
PARAKEET_URL = ("https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v2-gguf/resolve/"
                "07cee0616125a08ef619729bb47f40ef747e4bc4/parakeet-tdt-0.6b-v2-Q8_0.gguf")
PARAKEET_SHA = "f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa"
ENGINES = ["inserted", "qvac", "whisper", "apple", "parakeet"]


# MARK: References

def read_references():
    """Rows of references.tsv: stem, status (draft or ok), outcome, reference text."""
    if not REFERENCES.exists():
        return []
    with REFERENCES.open(newline="") as f:
        return [row for row in csv.reader(f, delimiter="\t") if row and not row[0].startswith("#")]


def hushhh_transcript(stem):
    """How the dictation ended and what Hushhh made of it, from <stem>.txt."""
    lines = (RECORDINGS / f"{stem}.txt").read_text().splitlines()
    return (lines[0] if lines else ""), " ".join(lines[1:]).strip()


def draft():
    BENCH.mkdir(parents=True, exist_ok=True)
    rows = read_references()
    known = {row[0] for row in rows}
    new = []
    for wav in sorted(RECORDINGS.glob("*.wav")):
        if wav.stem in known or not wav.with_suffix(".txt").exists():
            continue
        outcome, text = hushhh_transcript(wav.stem)
        new.append([wav.stem, "draft", outcome, text])
    write_header = not REFERENCES.exists()
    with REFERENCES.open("a", newline="") as f:
        if write_header:
            f.write("# recording\tstatus (draft → ok once the text is what you said)\toutcome\twhat you said\n")
        csv.writer(f, delimiter="\t", lineterminator="\n").writerows(new)
    print(f"Added {len(new)} recordings to {REFERENCES} ({len(rows) + len(new)} in all).")


# MARK: Engines

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(url, path, digest):
    if path.exists() and sha256(path) == digest:
        return path
    print(f"Downloading {url.rsplit('/', 1)[-1]}…", file=sys.stderr)
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".part")
    urllib.request.urlretrieve(url, partial)
    if sha256(partial) != digest:
        partial.unlink()
        sys.exit(f"Checksum mismatch for {url}")
    partial.rename(path)
    return path


def build_tool(name, extra=()):
    binary = TOOLS / name
    source = REPO / f"scripts/benchmark/{name}.swift"
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        TOOLS.mkdir(parents=True, exist_ok=True)
        flags = ["-parse-as-library"] if name == "AppleSpeech" else []
        subprocess.run(["swiftc", "-O", *flags, str(source), "-o", str(binary), *extra], check=True)
    return binary


def parakeet_tool():
    framework = TOOLS / "TranscribeCpp.xcframework/macos-arm64_x86_64"
    if not framework.exists():
        archive = fetch(FRAMEWORK_URL, TOOLS / "TranscribeCpp.xcframework.zip", FRAMEWORK_SHA)
        # ditto keeps the framework's symlinks, which Python's zipfile drops.
        subprocess.run(["ditto", "-x", "-k", str(archive), str(TOOLS)], check=True)
    model = fetch(PARAKEET_URL, TOOLS / "parakeet-tdt-0.6b-v2-Q8_0.gguf", PARAKEET_SHA)
    tool = build_tool("Parakeet", ["-F", str(framework), "-framework", "CTranscribe",
                                   "-Xlinker", "-rpath", "-Xlinker", str(framework)])
    return tool, model


def transcribe_batch(engine, wavs, whisper_model):
    """{stem: (seconds, text)} for `wavs`, one engine."""
    if engine in ("apple", "parakeet"):
        if engine == "apple":
            command = [str(build_tool("AppleSpeech"))]
        else:
            tool, model = parakeet_tool()
            command = [str(tool), str(model)]
        out = subprocess.run(command + [str(w) for w in wavs], capture_output=True, text=True).stdout
        results = {}
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                results[Path(parts[0]).stem] = (float(parts[1]), parts[2])
        return results

    results = {}
    env = dict(os.environ, HUSHHH_DEV="1")
    for wav in wavs:
        command = [str(APP), "--transcribe", str(wav), "--engine", engine, "--whole"]
        if engine == "whisper" and whisper_model:
            command += ["--whisper-model", whisper_model]
        out = subprocess.run(command, capture_output=True, text=True, env=env, errors="replace").stdout
        match = re.search(r"^final \(([\d.]+)s for [\d.]+s of audio\): (.*)$", out, re.M)
        results[wav.stem] = (float(match.group(1)), match.group(2)) if match else (0.0, "")
    return results


def cached(engine, stems, whisper_model):
    """{stem: (seconds, text)}, transcribing only what isn't cached yet."""
    if engine == "inserted":
        return {stem: (0.0, hushhh_transcript(stem)[1]) for stem in stems}
    label = f"whisper-{whisper_model}" if engine == "whisper" else engine
    folder = BENCH / "cache" / label
    folder.mkdir(parents=True, exist_ok=True)
    missing = [RECORDINGS / f"{s}.wav" for s in stems if not (folder / f"{s}.tsv").exists()]
    missing = [w for w in missing if w.exists()]
    if missing:
        print(f"{label}: transcribing {len(missing)} recordings…", file=sys.stderr)
        for stem, (seconds, text) in transcribe_batch(engine, missing, whisper_model).items():
            (folder / f"{stem}.tsv").write_text(f"{seconds}\t{text}")
    results = {}
    for stem in stems:
        path = folder / f"{stem}.tsv"
        if path.exists():
            seconds, _, text = path.read_text().partition("\t")
            results[stem] = (float(seconds), text)
    return results


# MARK: Scoring

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + number_words(n % 100))
    if n < 1_000_000:
        return number_words(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + number_words(n % 1000))
    return str(n)


def words(text):
    """Lowercase words without punctuation, numbers spelled out, so only words count."""
    text = text.lower().replace("’", "'").replace("-", " ")
    text = re.sub(r"\d+", lambda m: f" {number_words(int(m.group()))} ", text)
    text = re.sub(r"[^a-z0-9' ]+", " ", text)
    return [w.strip("'") for w in text.split() if w.strip("'")]


def errors(reference, hypothesis):
    """Word edits (substitutions, deletions, insertions) from reference to hypothesis."""
    r, h = words(reference), words(hypothesis)
    previous = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        current = [i] + [0] * len(h)
        for j in range(1, len(h) + 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r[i - 1] != h[j - 1]))
        previous = current
    return previous[len(h)], len(r)


def run(args):
    rows = [row for row in read_references() if len(row) >= 4 and (row[1] == "ok" or args.include_drafts)]
    if not rows:
        sys.exit(f"No reviewed recordings yet. Run `{sys.argv[0]} draft`, correct {REFERENCES}, and mark rows ok.")
    whisper_model = args.whisper_model or subprocess.run(
        ["defaults", "read", "com.graizlabs.hushhh", "whisperModel"], capture_output=True, text=True).stdout.strip()
    if any(e in args.engines for e in ("qvac", "whisper")) and not APP.exists():
        sys.exit("Build Hushhh first: make debug")
    references = {row[0]: row[3] for row in rows}
    stems = sorted(references)

    print(f"{len(stems)} recordings, {sum(len(words(t)) for t in references.values())} words\n")
    print(f"{'engine':<34}{'word error rate':>16}{'errors':>9}{'perfect':>10}{'avg time':>10}")
    details = []
    for engine in args.engines:
        results = cached(engine, stems, whisper_model)
        total_errors = total_words = perfect = 0
        seconds = []
        for stem in stems:
            if stem not in results:
                continue
            took, text = results[stem]
            e, n = errors(references[stem], text)
            total_errors += e
            total_words += n
            perfect += e == 0
            seconds.append(took)
            if e:
                details.append((stem, engine, e, text))
        short = whisper_model.removeprefix("openai_whisper-").split("_")[0]
        label = f"whisper ({short})" if engine == "whisper" else engine
        rate = total_errors / total_words if total_words else 0
        avg = f"{sum(seconds) / len(seconds):.2f}s" if seconds and engine != "inserted" else "–"
        print(f"{label:<34}{rate:>15.1%}{total_errors:>9}{perfect:>6}/{len(results):<3}{avg:>10}")

    if args.show:
        print()
        for stem in stems:
            mismatches = [d for d in details if d[0] == stem]
            if mismatches:
                print(f"{stem}\n  said:      {references[stem]}")
                for _, engine, e, text in mismatches:
                    print(f"  {engine + ':':<10} {text}  ({e} {'error' if e == 1 else 'errors'})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("draft", help="add new recordings to references.tsv")
    r = sub.add_parser("run", help="score each engine")
    r.add_argument("--engines", type=lambda s: s.split(","), default=ENGINES)
    r.add_argument("--whisper-model", help="a WhisperKit model ID; default: Hushhh's Whisper model")
    r.add_argument("--include-drafts", action="store_true", help="also score rows not yet marked ok")
    r.add_argument("--show", action="store_true", help="list every mismatch")
    args = parser.parse_args()
    draft() if args.command == "draft" else run(args)


if __name__ == "__main__":
    main()
