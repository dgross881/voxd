defmodule Voxd.Transcriber.Bumblebee do
  @moduledoc """
  Bumblebee/EXLA implementation of `Voxd.Transcriber` backed by
  `distil-whisper/distil-large-v3`.

  The model is loaded once into a `model_info`/featurizer/tokenizer/
  generation-config bundle (`load/0`) and shared by **two** `Nx.Serving`s
  built from it:

    * `final_serving/1` — chunked 30 s transcription for the final pass.
    * `watcher_serving/1` — greedy with a small `max_new_tokens` cap and no
      chunking, for the 2 s stop-phrase watcher windows.

  Both servings reference the same weights, so the watcher adds no extra VRAM
  (only its `generation_config` differs). Bumblebee 0.7 fixes the generation
  strategy at serving-build time, which is why a second serving is required
  rather than a per-call override.

  Input is a 1-D 16 kHz mono `f32` `Nx.Tensor` (the caller does
  `Nx.from_binary(pcm, :f32)`). Output text is the joined-and-trimmed
  `result.chunks`.
  """

  @behaviour Voxd.Transcriber

  alias Bumblebee.Audio
  alias Nx.Serving

  @repo {:hf, "distil-whisper/distil-large-v3"}
  @watcher_max_new_tokens 24
  @final_chunk_num_seconds 30

  @typedoc "The loaded model bundle shared by both servings."
  @type model_bundle :: %{
          model_info: map(),
          featurizer: Bumblebee.Featurizer.t(),
          tokenizer: Bumblebee.Tokenizer.t(),
          generation_config: Bumblebee.Configurable.t()
        }

  @doc """
  Loads the distil-large-v3 model bundle (model, featurizer, tokenizer,
  generation config) in `f16`.

  First call downloads ~1.5 GB from HuggingFace; subsequent calls read the
  Bumblebee cache.
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
  Builds the final-pass serving: chunked 30 s, English transcription, greedy.
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
  Builds the watcher serving: greedy, `max_new_tokens: #{@watcher_max_new_tokens}`,
  no chunking — sized for 2 s stop-phrase windows.
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
  Runs `serving` on a 1-D 16 kHz mono `f32` audio tensor and returns the
  joined, trimmed transcription text.

  Pass the serving handle via `opts[:serving]` (an `Nx.Serving` struct for
  inline `run/2`, or a registered process name for `batched_run/2`).
  """
  @impl Voxd.Transcriber
  @spec transcribe(Nx.Tensor.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(audio, opts) do
    serving = Keyword.fetch!(opts, :serving)
    result = Serving.run(serving, audio)
    {:ok, join_chunks(result)}
  rescue
    error -> {:error, error}
  end

  @doc """
  The persistent XLA compilation-cache directory (`~/.cache/voxd/xla`),
  created if absent.
  """
  @spec cache_dir() :: String.t()
  def cache_dir do
    dir = Path.expand("~/.cache/voxd/xla")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  The EXLA client atom from config (`:cuda` in dev, `:host` in test).
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
