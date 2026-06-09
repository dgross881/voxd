defmodule Voxd.Transcriber.Bumblebee do
  @moduledoc """
  The real speech-to-text engine: Whisper (`distil-whisper/distil-large-v3`)
  running on the GPU via Bumblebee and EXLA.

  The model is loaded **once** (`load/0` — about 1.5 GB of weights) and then
  shared by two separately tuned "servings" (a serving is a running,
  compiled instance of the model ready to take requests):

    * `final_serving/1` — the careful pass. Handles takes of any length by
      processing them in 30-second chunks; used when you stop a recording.
    * `watcher_serving/1` — the quick pass. Capped at a few output words and
      no chunking, sized for the 2-second windows the stop-phrase watcher
      checks every second while you talk.

  Both servings point at the same weights, so the second one costs no extra
  GPU memory — only its generation settings differ. (Bumblebee fixes those
  settings when a serving is built, which is why there are two servings
  rather than one with a per-call option.)

  How the Session uses it:

      tensor = Nx.from_binary(pcm, :f32)          # raw mic bytes → tensor
      {:ok, text} = Bumblebee.transcribe(tensor, serving: :final)

  Input is always 1-D 16 kHz mono `f32` audio. The output text is the
  model's chunks joined together and trimmed.
  """

  @behaviour Voxd.Transcriber

  alias Bumblebee.Audio
  alias Nx.Serving

  @repo {:hf, "distil-whisper/distil-large-v3"}
  @watcher_max_new_tokens 24
  @final_chunk_num_seconds 30

  @final_serving_name Voxd.Serving.Final
  @watcher_serving_name Voxd.Serving.Watcher

  @typedoc "The loaded model bundle shared by both servings."
  @type model_bundle :: %{
          model_info: map(),
          featurizer: Bumblebee.Featurizer.t(),
          tokenizer: Bumblebee.Tokenizer.t(),
          generation_config: Bumblebee.Configurable.t()
        }

  @doc """
  Load the Whisper model bundle (weights, featurizer, tokenizer, generation
  config) in half-precision (`f16`).

  The first call ever downloads ~1.5 GB from HuggingFace; after that the
  local Bumblebee cache is used and loading takes a few seconds.
  """
  @spec load() :: model_bundle()
  def load do
    # backend is explicit: without it the f32→f16 cast of 1.5B params runs on
    # Nx.BinaryBackend (pure Elixir) and takes ~260 s instead of ~3 s.
    {:ok, model_info} =
      Bumblebee.load_model(@repo, type: :f16, backend: {EXLA.Backend, client: :host})

    {:ok, featurizer} = Bumblebee.load_featurizer(@repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(@repo)
    {:ok, generation_config} = Bumblebee.load_generation_config(@repo)

    %{
      model_info: model_info,
      featurizer: featurizer,
      tokenizer: tokenizer,
      generation_config: generation_config
    }
  end

  @doc """
  Build the careful final-pass serving: English transcription in 30-second
  chunks, so a take of any length comes out whole.
  """
  @spec final_serving(model_bundle()) :: Serving.t()
  def final_serving(bundle) do
    Audio.speech_to_text_whisper(
      bundle.model_info,
      bundle.featurizer,
      bundle.tokenizer,
      bundle.generation_config,
      chunk_num_seconds: @final_chunk_num_seconds,
      language: "en",
      task: :transcribe,
      compile: [batch_size: 1],
      defn_options: defn_options()
    )
  end

  @doc """
  Build the quick watcher serving: output capped at
  #{@watcher_max_new_tokens} tokens, no chunking — just enough to spot a
  stop phrase in a 2-second window.
  """
  @spec watcher_serving(model_bundle()) :: Serving.t()
  def watcher_serving(bundle) do
    Audio.speech_to_text_whisper(
      bundle.model_info,
      bundle.featurizer,
      bundle.tokenizer,
      watcher_generation_config(bundle.generation_config),
      language: "en",
      task: :transcribe,
      compile: [batch_size: 1],
      defn_options: defn_options()
    )
  end

  @doc """
  The registered process name of the final-pass serving (`#{inspect(@final_serving_name)}`).
  """
  @spec final_serving_name() :: module()
  def final_serving_name, do: @final_serving_name

  @doc """
  The registered process name of the watcher serving (`#{inspect(@watcher_serving_name)}`).
  """
  @spec watcher_serving_name() :: module()
  def watcher_serving_name, do: @watcher_serving_name

  @doc """
  Transcribe audio (a 1-D 16 kHz mono `f32` tensor) and return the joined,
  trimmed text. Any error comes back as `{:error, reason}` rather than
  raising.

  `opts[:serving]` picks which engine answers:

    * `:final` / `:watcher` — the named serving processes started by
      `Voxd.Transcriber.ServingLoader` (the daemon path).
    * an `%Nx.Serving{}` struct — run it directly, no supervision tree
      needed (the benchmark path).
  """
  @impl Voxd.Transcriber
  @spec transcribe(Nx.Tensor.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(audio, opts) do
    result = run_serving(Keyword.fetch!(opts, :serving), audio)
    {:ok, join_chunks(result)}
  rescue
    error -> {:error, error}
  end

  @spec run_serving(:final | :watcher | Serving.t(), Nx.Tensor.t()) :: map()
  defp run_serving(:final, audio), do: Serving.batched_run(@final_serving_name, audio)
  defp run_serving(:watcher, audio), do: Serving.batched_run(@watcher_serving_name, audio)
  defp run_serving(%Serving{} = serving, audio), do: Serving.run(serving, audio)

  @doc """
  The directory where compiled GPU programs are cached between runs
  (`~/.cache/voxd/xla`), created if absent. The cache is what makes the
  second boot far faster than the first.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    dir = Path.expand("~/.cache/voxd/xla")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Where the model runs, from config: `:cuda` (the GPU) in dev/prod,
  `:host` (the CPU) in test.
  """
  @spec client() :: atom()
  def client, do: Application.fetch_env!(:voxd, :exla_client)

  @spec defn_options() :: keyword()
  defp defn_options do
    [compiler: EXLA, client: client(), cache: cache_dir()]
  end

  @spec watcher_generation_config(Bumblebee.Configurable.t()) :: Bumblebee.Configurable.t()
  defp watcher_generation_config(generation_config) do
    Bumblebee.configure(generation_config,
      strategy: %{type: :greedy_search},
      max_new_tokens: @watcher_max_new_tokens
    )
  end

  @spec join_chunks(%{chunks: list(map())}) :: String.t()
  defp join_chunks(%{chunks: chunks}) do
    chunks
    |> Enum.map_join(& &1.text)
    |> String.trim()
  end
end
