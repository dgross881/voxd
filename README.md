# voxd

Voice-to-text daemon for Linux / Wayland, written in Elixir.

Hold a key (or run a command), speak, and voxd transcribes your speech with
Whisper and types it straight into whatever window has focus. An optional
"AI" mode pipes the transcript through a local Ollama model to clean it up
before typing.

voxd has two pieces:

| Piece    | What it is                          | How it runs                     |
|----------|-------------------------------------|---------------------------------|
| `voxd`   | The daemon — mic, model, typing     | Mix **release** (long-lived)    |
| `voxctl` | The control CLI your hotkey runs    | Mix **escript** (one-shot)      |

`voxctl` talks to `voxd` over a Unix socket (`/tmp/voxd.sock`). The daemon
boots in under a second and loads the speech model in the background, so the
socket answers `loading` until the model is ready, then `idle`.

---

## Requirements

**Runtime tools** (must be on `PATH`):

- **Elixir ~> 1.19** on **Erlang/OTP 28**
- **PipeWire** — `pw-record` captures the microphone
- **ydotool** — types the transcript; its daemon must be running and reachable
  at `$XDG_RUNTIME_DIR/.ydotool_socket` (i.e. `/run/user/<uid>/.ydotool_socket`)
- **wl-clipboard** — `wl-copy` stages the text on the clipboard as a fallback
- **Python 3 + GTK 3 bindings** (PyGObject) — draws the on-screen overlay card
  (`priv/overlay/overlay.py`). The daemon still runs without a display; the
  overlay is optional.

**GPU (speech model):** voxd runs Whisper (`distil-whisper/distil-large-v3`,
~1.5 GB) through Bumblebee + EXLA on an NVIDIA GPU. EXLA is linked against
CUDA 13 (`XLA_TARGET=cuda13`). The CUDA libraries come from the pip NVIDIA
wheels rather than a system CUDA install — see [GPU setup](#gpu-setup).

**AI mode (optional):** a running [Ollama](https://ollama.com) instance with
the model named in your config pulled.

**Hotkey (optional):** to use the built-in press-and-hold hotkey, the user
must be in the `input` group (voxd reads the keyboard directly via evdev).

---

## Setup

### 1. Get dependencies

```sh
mix deps.get
```

### 2. GPU setup

EXLA needs the CUDA 13 runtime and an XLA "CUDA data dir" containing `ptxas`
and `libdevice`. The release sources these at boot via `rel/env.sh.eex`
(mirrored by `bin/gpu-env` for `mix run`):

- CUDA libraries are discovered from the pip NVIDIA wheels under
  `~/.local/lib/python<ver>/site-packages/nvidia/*/lib`.
- `XLA_FLAGS` points XLA at `~/.cache/voxd/cuda-data-dir`, which must contain
  symlinks to `bin/ptxas` (from the `torch` wheel) and
  `nvvm/libdevice/libdevice.10.bc` (from the `triton` wheel).

Create that data dir once, pointing the two symlinks at wherever pip installed
`torch`/`triton` on your machine:

```sh
mkdir -p ~/.cache/voxd/cuda-data-dir/bin ~/.cache/voxd/cuda-data-dir/nvvm/libdevice
ln -sf "$(python3 -c 'import torch, os; print(os.path.join(os.path.dirname(torch.__file__), "bin", "ptxas"))')" \
       ~/.cache/voxd/cuda-data-dir/bin/ptxas
ln -sf "$(python3 -c 'import triton, os, glob; print(glob.glob(os.path.join(os.path.dirname(triton.__file__), "backends", "nvidia", "lib", "libdevice*.bc"))[0])')" \
       ~/.cache/voxd/cuda-data-dir/nvvm/libdevice/libdevice.10.bc
```

> If your machine *can* infer `XLA_TARGET` (nvcc on `PATH`, system CUDA), much
> of this is unnecessary — adjust to your environment.

### 3. Build and run the daemon

The daemon runs as a Mix release, **not** from source — rebuild the release
after any code change.

```sh
XLA_TARGET=cuda13 mix release --overwrite
```

Then start it:

```sh
# foreground (logs to stdout and /tmp/voxd.log)
_build/dev/rel/voxd/bin/voxd start

# or detached
_build/dev/rel/voxd/bin/voxd daemon
```

The first start is slow — it loads and compiles the model. Watch progress with
`tail -f /tmp/voxd.log`. `voxctl status` reports `loading` until it's ready.

### 4. Build and install `voxctl`

```sh
cd voxctl
mix escript.build
```

Put the resulting `voxctl` executable somewhere on your `PATH`
(e.g. `~/.local/bin/voxctl`).

---

## Usage

```sh
voxctl toggle               # start a dictation recording; run again to stop + type
voxctl toggle --mode ai     # same, but polish the transcript via Ollama first
voxctl cancel               # abandon the current recording
voxctl status               # loading | idle | recording
voxctl history --n 10       # show the last 10 transcriptions
voxctl history --copy 3     # re-type entry #3 from that listing
```

Recording is **toggle / push-to-talk**: the first `toggle` starts capture, the
second stops it, transcribes, and types the result into the focused window.

### Triggering it with a key

Two options:

1. **Compositor keybinding** — bind a key in GNOME/KDE/sway to run
   `voxctl toggle` (and optionally another to `voxctl toggle --mode ai`).
2. **Built-in evdev hotkey** — let voxd watch the keyboard itself for a
   press-and-hold. Enable it in the config (below). This works on Wayland
   without compositor support, at the cost of needing `input`-group access.

---

## Configuration

voxd reads `~/.config/voxd/config.toml`. Every key is optional; omitted keys
use built-in defaults. Copy the example to start:

```sh
mkdir -p ~/.config/voxd
cp priv/config.toml.example ~/.config/voxd/config.toml
```

```toml
[ai]
# Ollama model used in AI mode (voxctl toggle --mode ai).
model = "deepseek-r1:14b"
# Base URL of your Ollama instance.
ollama_url = "http://localhost:11434"

[hotkey]
# Built-in press-and-hold hotkey (read directly from the keyboard via evdev).
# Off unless enabled = true. Requires the voxd user to be in the `input` group.
enabled = false
# Exact kernel device name (see: cat /sys/class/input/event*/device/name).
device_name = "My Keyboard"
# evdev key code to watch. Discover yours with:
#   libinput debug-events --show-keycodes
keycode = 464
# How long (ms) the key must be held before voxd toggles a recording.
hold_ms = 1000
# Which mode the hold triggers: "dictation" or "ai".
mode = "dictation"
```

Changes to `[hotkey]` take effect on the next daemon start.

### Paths and environment

| Thing            | Location                                    | Override        |
|------------------|---------------------------------------------|-----------------|
| Config           | `~/.config/voxd/config.toml`                | —               |
| History          | `~/.local/share/voxd/history.jsonl`         | —               |
| Control socket   | `/tmp/voxd.sock`                            | `VOXD_SOCKET`   |
| Log file         | `/tmp/voxd.log`                             | —               |
| PID file         | `/tmp/voxd.pid`                             | —               |
| CUDA data dir    | `~/.cache/voxd/cuda-data-dir`               | `XLA_FLAGS`     |

---

## Development

```sh
# verify loop
XLA_TARGET=cuda13 mix compile --warnings-as-errors && mix format && mix test
```

The test suite runs with **no microphone, GPU, or display** — external
programs are stubbed and the model is mocked. Run mix commands one at a time
(never in parallel or background): they share `_build`.

---

## How it fits together

```
your hotkey ──> voxctl ──(/tmp/voxd.sock)──> voxd daemon
                                              ├── Recorder   (pw-record → PCM)
                                              ├── Transcriber (Whisper / EXLA)
                                              ├── AI (optional, Ollama)
                                              ├── Typist     (wl-copy + ydotool)
                                              └── Overlay    (GTK card)
```
