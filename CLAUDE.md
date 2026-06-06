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
