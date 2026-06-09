defmodule Voxd.Transcriber do
  @moduledoc """
  The contract every speech-to-text backend must fulfill: audio in,
  text out.

  A transcriber takes audio (a 1-D 16 kHz mono `f32` tensor) and returns
  `{:ok, text}` or `{:error, reason}`. Which backend is used comes from the
  `:voxd, :transcriber` application setting — the daemon runs
  `Voxd.Transcriber.Bumblebee` (Whisper on the GPU), while tests swap in
  `Voxd.Transcriber.Mock` so the suite needs no GPU at all. This seam is
  also the escape hatch: a `whisper.cpp`-based backend could slot in
  without touching the rest of the daemon.
  """

  @doc """
  Transcribe audio (a 1-D 16 kHz mono `f32` tensor) to text.

  `opts` may carry backend-specific keys (e.g. `serving: :final | :watcher`
  for the Bumblebee backend).
  """
  @callback transcribe(Nx.Tensor.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
end
