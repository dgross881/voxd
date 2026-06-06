#!/usr/bin/env python3
"""faster-whisper baseline for the voxd transcriber gate.

Mirrors the linux-voice Python daemon's exact settings so the Elixir
(Bumblebee, greedy) numbers can be compared apples-to-apples:

  final pass:   beam_size=5, language="en", vad_filter=True
  watcher path: beam_size=1, language="en", condition_on_previous_text=False

Model: distil-large-v3 on CUDA, compute_type float16. Warm model, median of 3.

Run:  python3 bench/python_baseline.py
"""

import os
import statistics
import time

from faster_whisper import WhisperModel

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")
MEDIAN_RUNS = 3


def median_latency(fn):
    """Run fn() once to warm, then MEDIAN_RUNS timed runs; return (median_s, last_text)."""
    fn()  # warm-up
    samples = []
    text = ""
    for _ in range(MEDIAN_RUNS):
        start = time.perf_counter()
        text = fn()
        samples.append(time.perf_counter() - start)
    return statistics.median(samples), text


def transcribe_final(model, wav):
    segments, _ = model.transcribe(
        wav, beam_size=5, language="en", vad_filter=True
    )
    return "".join(seg.text for seg in segments).strip()


def transcribe_watcher(model, wav):
    segments, _ = model.transcribe(
        wav, beam_size=1, language="en", condition_on_previous_text=False
    )
    return "".join(seg.text for seg in segments).strip()


def main():
    print("Loading distil-large-v3 (cuda, float16)...")
    t0 = time.perf_counter()
    model = WhisperModel("distil-large-v3", device="cuda", compute_type="float16")
    print(f"Model load: {time.perf_counter() - t0:.2f} s\n")

    clip5 = os.path.join(FIXTURES, "clip_5s.wav")
    clip30 = os.path.join(FIXTURES, "clip_30s.wav")
    clip2 = os.path.join(FIXTURES, "clip_2s.wav")

    print("## Python faster-whisper baseline\n")
    print("| Path | Clip | Median latency (s) |")
    print("|------|------|--------------------|")

    lat5, text5 = median_latency(lambda: transcribe_final(model, clip5))
    print(f"| final (beam 5) | 5 s | {lat5:.3f} |")

    lat30, text30 = median_latency(lambda: transcribe_final(model, clip30))
    print(f"| final (beam 5) | 30 s | {lat30:.3f} |")

    lat2, text2 = median_latency(lambda: transcribe_watcher(model, clip2))
    print(f"| watcher (beam 1) | 2 s | {lat2:.3f} |")

    print("\n## Transcripts\n")
    print(f"- 5 s : {text5!r}")
    print(f"- 30 s: {text30!r}")
    print(f"- 2 s : {text2!r}")


if __name__ == "__main__":
    main()
