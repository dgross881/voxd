#!/bin/sh
# Generate benchmark audio fixtures for the transcriber benchmark.
#
# Produces, in bench/fixtures/:
#   clip_5s.{wav,raw}   ~5 s English speech  (~15 words)
#   clip_30s.{wav,raw}  ~30 s English speech (~90 words)
#   clip_2s.{wav,raw}   ~2 s  "end recording" stop-phrase (watcher sanity check)
#   noise_2s.{wav,raw}  2 s low noise floor (vol 0.002)
#   (digital-zeros silence is generated in Elixir directly — see the bench script)
#
# .wav  = 16 kHz mono PCM      (for the Python faster-whisper baseline)
# .raw  = 16 kHz mono f32le    (for Elixir Nx.from_binary/2)
#
# espeak-ng emits 22050 Hz; ffmpeg resamples to 16 kHz mono.
# Requires: espeak-ng, ffmpeg, sox.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)/fixtures"
mkdir -p "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# espeak speed: 150 wpm default. ~15 words ≈ 5 s, ~90 words ≈ 30 s at -s 150.
say() { # say <out_basename> <speed_wpm> <text>
  out="$1"; speed="$2"; text="$3"
  espeak-ng -s "$speed" -v en-us -w "$TMP/$out.wav" "$text"
  ffmpeg -y -loglevel error -i "$TMP/$out.wav" -ar 16000 -ac 1 "$DIR/$out.wav"
  ffmpeg -y -loglevel error -i "$DIR/$out.wav" -ar 16000 -ac 1 -f f32le "$DIR/$out.raw"
}

say clip_5s 150 \
  "The quick brown fox jumps over the lazy dog while the morning sun rises slowly."

say clip_30s 150 \
  "Good morning everyone and welcome to today's short briefing on the state of the project. \
We have made steady progress over the last several weeks across testing, documentation, and the user interface. \
The team remains focused on shipping a reliable release that meets our quality standards. \
Please review the latest notes before our meeting and bring any questions you might have about the timeline."

# ~2 s window containing a stop phrase, to sanity-check the watcher path.
say clip_2s 130 "okay, end recording now please"

# Low noise floor: 2 s of quiet white noise, then convert to 16 kHz f32 raw + wav.
sox -n -r 16000 -c 1 "$TMP/noise.wav" synth 2 whitenoise vol 0.002
ffmpeg -y -loglevel error -i "$TMP/noise.wav" -ar 16000 -ac 1 "$DIR/noise_2s.wav"
ffmpeg -y -loglevel error -i "$DIR/noise_2s.wav" -ar 16000 -ac 1 -f f32le "$DIR/noise_2s.raw"

echo "Fixtures written to $DIR:"
ls -la "$DIR"
