# Transcriber benchmark / Phase-1 gate.
#
# Measures Voxd.Transcriber.Bumblebee (distil-large-v3, greedy, EXLA/cuda)
# against the linux-voice quality bar, and probes silence hallucination.
#
# MUST be run with the GPU env prefix:
#
#     bin/gpu-env mix run bench/transcribe_bench.exs
#
# Run it TWICE to see cold vs warm XLA persistent-cache compile time
# (the script reports whether the cache dir was empty before this run).

alias Voxd.Transcriber.Bumblebee, as: VB
alias Nx.Serving

defmodule Bench do
  @moduledoc false

  @fixtures Path.join(__DIR__, "fixtures")
  @sample_rate 16_000
  @watcher_window_seconds 2
  @median_runs 3
  @silence_windows 10
  @stop_phrase_regex ~r/\b(end\s+(?:recording|dictation|transcription|it|conversation)|stop\s+(?:recording|dictating)|done|end)\b/i

  @doc "Load a 16 kHz mono f32 raw fixture into a 1-D Nx tensor."
  def load_raw(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> Nx.from_binary(:f32)
  end

  @doc "First `seconds` of a 1-D f32 tensor (16 kHz)."
  def take_seconds(tensor, seconds) do
    samples = seconds * @sample_rate
    Nx.slice_along_axis(tensor, 0, min(samples, Nx.size(tensor)), axis: 0)
  end

  @doc "A window of digital-zero silence (2 s of f32 0.0), built directly in Elixir."
  def zeros_window do
    Nx.broadcast(Nx.tensor(0.0, type: :f32), {@watcher_window_seconds * @sample_rate})
  end

  @doc "Median wall-clock seconds of N timed runs of `fun`, plus its last result."
  def median(fun) do
    {_warm_us, result} = :timer.tc(fun)

    {samples, last} =
      Enum.reduce(1..@median_runs, {[], result}, fn _i, {acc, _last} ->
        {us, value} = :timer.tc(fun)
        {[us / 1_000_000 | acc], value}
      end)

    {Enum.sort(samples) |> median_of(), last}
  end

  defp median_of(sorted) do
    count = length(sorted)
    mid = div(count, 2)

    case rem(count, 2) do
      1 -> Enum.at(sorted, mid)
      0 -> (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  @doc "Run `count` silence windows through the watcher serving; classify outputs."
  def silence_probe(serving, window_fun, count) do
    results =
      for _i <- 1..count do
        {:ok, text} = VB.transcribe(window_fun.(), serving: serving)
        text
      end

    non_empty = Enum.reject(results, &(&1 == ""))
    stop_hits = Enum.filter(non_empty, &Regex.match?(@stop_phrase_regex, &1))
    {non_empty, stop_hits}
  end

  def stop_phrase_regex, do: @stop_phrase_regex
  def watcher_window_seconds, do: @watcher_window_seconds
  def silence_windows, do: @silence_windows
end

# --- cache warmth (cold vs warm) -------------------------------------------

cache_dir = Path.expand("~/.cache/voxd/xla")
cache_was_empty? = not File.dir?(cache_dir) or File.ls!(cache_dir) == []
warmth = if cache_was_empty?, do: "COLD (cache dir was empty)", else: "WARM (cache populated)"

# --- model load -------------------------------------------------------------

{load_us, bundle} = :timer.tc(&VB.load/0)

# --- serving build + first-inference compile --------------------------------

clip_5s = Bench.load_raw("clip_5s.raw")
clip_30s = Bench.load_raw("clip_30s.raw")
clip_2s_full = Bench.load_raw("clip_2s.raw")
clip_2s = Bench.take_seconds(clip_2s_full, Bench.watcher_window_seconds())
noise_2s = Bench.load_raw("noise_2s.raw") |> Bench.take_seconds(Bench.watcher_window_seconds())

final = VB.final_serving(bundle)
watcher = VB.watcher_serving(bundle)

# Force compilation by running one inference on each serving; time it.
{final_compile_us, _} = :timer.tc(fn -> Serving.run(final, clip_5s) end)
{watcher_compile_us, _} = :timer.tc(fn -> Serving.run(watcher, clip_2s) end)

# --- warm latencies ---------------------------------------------------------

{final_5s_lat, text_5s} = Bench.median(fn -> VB.transcribe(clip_5s, serving: final) end)
{final_30s_lat, text_30s} = Bench.median(fn -> VB.transcribe(clip_30s, serving: final) end)
{watcher_2s_lat, text_2s} = Bench.median(fn -> VB.transcribe(clip_2s, serving: watcher) end)

# --- silence hallucination (F4) --------------------------------------------

{zeros_non_empty, zeros_stop} =
  Bench.silence_probe(watcher, &Bench.zeros_window/0, Bench.silence_windows())

{noise_non_empty, noise_stop} =
  Bench.silence_probe(watcher, fn -> noise_2s end, Bench.silence_windows())

# --- report -----------------------------------------------------------------

us_to_s = fn us -> Float.round(us / 1_000_000, 3) end
fmt = fn s -> :erlang.float_to_binary(s * 1.0, decimals: 3) end

IO.puts("\n# voxd transcriber benchmark\n")
IO.puts("XLA cache: #{warmth}  (dir: #{cache_dir})\n")

IO.puts("## Timings\n")
IO.puts("| Metric | Value (s) |")
IO.puts("|--------|-----------|")
IO.puts("| Model load (Bumblebee.load_model + featurizer/tokenizer/genconfig) | #{us_to_s.(load_us)} |")
IO.puts("| Final serving build + first inference (compile) | #{us_to_s.(final_compile_us)} |")
IO.puts("| Watcher serving build + first inference (compile) | #{us_to_s.(watcher_compile_us)} |")
IO.puts("| Final-pass latency, 5 s clip (warm, median of #{3}) | #{fmt.(final_5s_lat)} |")
IO.puts("| Final-pass latency, 30 s clip (warm, median of #{3}) | #{fmt.(final_30s_lat)} |")
IO.puts("| Watcher latency, 2 s clip (warm, median of #{3}) | #{fmt.(watcher_2s_lat)} |")

IO.puts("\n## Silence hallucination (F4) — watcher serving, #{Bench.silence_windows()} windows each\n")
IO.puts("Stop-phrase regex: #{inspect(Bench.stop_phrase_regex())}\n")
IO.puts("| Source | Non-empty | Stop-phrase matches |")
IO.puts("|--------|-----------|---------------------|")
IO.puts("| Digital zeros | #{length(zeros_non_empty)} / #{Bench.silence_windows()} | #{length(zeros_stop)} |")
IO.puts("| Noise floor (vol 0.002) | #{length(noise_non_empty)} / #{Bench.silence_windows()} | #{length(noise_stop)} |")

IO.puts("\nSample non-empty hallucinations (zeros): #{inspect(Enum.take(zeros_non_empty, 5))}")
IO.puts("Sample non-empty hallucinations (noise): #{inspect(Enum.take(noise_non_empty, 5))}")
IO.puts("Stop-phrase-matching hallucinations (zeros): #{inspect(zeros_stop)}")
IO.puts("Stop-phrase-matching hallucinations (noise): #{inspect(noise_stop)}")

IO.puts("\n## Transcripts (voxd greedy)\n")
IO.puts("- 5 s : #{inspect(text_5s)}")
IO.puts("- 30 s: #{inspect(text_30s)}")
IO.puts("- 2 s (watcher): #{inspect(text_2s)}")
IO.puts("")
