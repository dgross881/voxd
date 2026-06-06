defmodule Voxd.Transcriber do
  @moduledoc """
  Behaviour for speech-to-text backends.

  A transcriber takes a 1-D 16 kHz mono `f32` audio tensor and returns the
  transcribed text. Implementations are selected via the `:voxd, :transcriber`
  application env so tests can swap in `Voxd.Transcriber.Mock` (no GPU) while
  the daemon uses `Voxd.Transcriber.Bumblebee`.
  """

  @doc """
  Transcribes a 1-D 16 kHz mono `f32` audio tensor.

  `opts` may carry implementation-specific keys (e.g. `serving: :final | :watcher`
  for the Bumblebee backend).
  """
  @callback transcribe(Nx.Tensor.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
