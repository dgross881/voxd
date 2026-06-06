# voxd

Voice-to-text daemon for Linux/Wayland. Elixir rewrite of the Python
`linux-voice` project (`~/sites/linux-voice`) — behavior-identical port.

**Spec:** `~/sites/linux-voice/docs/superpowers/specs/2026-06-06-voxd-elixir-rewrite-design.md`
**Plan:** `.claude/plans/voxd/plan.md` · **Scratchpad:** `.claude/plans/voxd/scratchpad.md`
**Behavioral reference:** `.claude/plans/voxd/research/python-daemon-behavior.md`
(exact regexes, protocols, constants from the Python daemon — port 1:1).

## Code style (mandatory)

- `@moduledoc` on every module; `@doc` + `@spec` on every public function.
- Small single-purpose functions with literal names (`classify_drift`, not
  `do_work`); extract a helper past ~15 lines or more than one conceptual step.
- Pattern-matched function heads over `cond`/nested `if`; `case` over
  single-clause `with`+`else`.
- Always `alias` modules — never fully-qualified names in code or tests.
- Explicit variable names; zero-arity style: `def enabled?` at definition,
  `enabled?()` at call sites.
- Don't add comments that restate the code — write the WHY when non-obvious.

## Tests

- Full suite must pass with **no mic, GPU, or display** (`exla_client: :host`
  in test; `Voxd.Transcriber.Mock` via Mox).
- Tests make falsifiable claims; never weaken a failing test; no `:skip`.
- External processes are stubbed with real binaries (`cat`, `sh -c`) and
  absolute fixture paths — see the Recorder tests.

## Commands

- Verify loop: `mix compile --warnings-as-errors && mix format && mix test`
- **Never run mix commands in parallel or in background** (shared `_build`).
- EXLA compile needs `XLA_TARGET=cuda13` (no nvcc on PATH, so xla can't infer
  it; driver 595 + pip CUDA-13 stack). CUDA libs come from pip
  (`~/.local/lib/python3.14/site-packages/nvidia/*/lib`) — see scratchpad.

## Dependency source for deep-diving

- nx + exla: `~/.opensrc/repos/github.com/elixir-nx/nx/main` (subdirs `nx/`, `exla/`)
- bumblebee: `~/.opensrc/repos/github.com/elixir-nx/bumblebee/main`
- Other deps readable in `deps/` after `mix deps.get`.
- Findings from source research go to `~/ObsidianVault/elixir-nx/` as notes.

## Commits

- Conventional prefixes (`feat:`, `fix:`, `test:`, `docs:`); no Co-Authored-By
  trailer. Ask before committing. Never commit `docs/superpowers/` or
  `.claude/plans/`.

## Status (2026-06-06)

- **Live and working as daily driver** — release boots, transcribes, types.
  Verified end-to-end with Jete MP2 USB wireless mic (commit `713abb9`).
- `voxctl` escript built and installed at `~/.local/bin/voxctl`
  (builds into the **repo root**, not `voxctl/`).
- In progress (uncommitted): decoupling from linux-voice paths — config →
  `~/.config/voxd/config.toml`, history → `~/.local/share/voxd/history.jsonl`.

## Key decisions (live-debugging session)

| Decision | Why |
|---|---|
| **No silence pre-filter** (removed `silent_audio?`/`peak_amplitude`) | Python has none; the 0.001 peak threshold treated USB-mic ambient noise as silence and blocked ALL transcription. All audio goes to Whisper, as Python does with `vad_filter=True`. |
| `meaningful?` = non-empty + no 10+ repeated chars | Was "must contain letter/digit", which swallowed Whisper's `"..."` on low-SNR audio silently. Now mirrors Python's `if not text:` while still catching `!!!!` hallucination runs. |
| `pcm_to_tensor/1` sanitizes NaN/Inf → 0.0 | Jete USB mic emits NaN samples while hardware settles; NaN into XLA **crashes the Nx.Serving process permanently** (no-process errors on all later calls). |
| Log raw Whisper output (`Logger.debug`) + `nothing_heard` warning | Pipeline used to fail silently — no log, no history, just an overlay flash. |

## Gotchas (cost real debugging time)

- **WirePlumber resets mic volume** below 100% between sessions — quiet input
  again. Check `pactl list sources` volume before suspecting code.
- **Stale `voxd@fedora` node name** blocks release start (`Protocol 'inet_tcp':
  the name ... in use`). Find the old BEAM with `pgrep -f beam.smp` and kill it
  (often a leftover `iex -S mix`).
- Release must be **rebuilt** (`XLA_TARGET=cuda13 mix release --overwrite`)
  after code changes — `voxd start` runs the compiled release, not the source.
- voxctl `IO.puts` in `cli.ex` is intentional CLI output, not debug statements
  (hook false-positives on it).

## Next steps

- [ ] Finish decoupling: add `priv/config.toml.example`; copy user's existing
      `~/.config/linux-voice/config.toml` + history to new voxd paths.
- [ ] Verify loop + commit the decoupling changes.
- [ ] Task 14 (plan): GNOME keybinding → `voxctl toggle`; burn-in; retire
      linux-voice.
