defmodule Voxd.Ready do
  @moduledoc """
  Tracks whether the transcription servings have finished loading.

  The flag is `:persistent_term`-backed (cheap concurrent reads from the control
  socket) and starts `false` so `status` reports `"loading"` until the
  serving-loader Task calls `mark_ready/1` after both `Nx.Serving`s are up.
  Marking ready also touches `/tmp/voxd-ready` (path injectable for tests) so an
  external watcher can poll the file instead of the socket.
  """

  @term_key {__MODULE__, :ready?}
  @default_ready_file "/tmp/voxd-ready"

  @doc """
  The `:persistent_term` key the readiness flag is stored under. Exposed so tests
  can reset state between cases.
  """
  @spec term_key() :: {module(), :ready?}
  def term_key, do: @term_key

  @doc """
  The default ready-file path (`#{@default_ready_file}`).
  """
  @spec default_ready_file() :: String.t()
  def default_ready_file, do: @default_ready_file

  @doc """
  Whether the servings are ready. `false` until `mark_ready/1` runs.
  """
  @spec ready?() :: boolean()
  def ready?, do: :persistent_term.get(@term_key, false)

  @doc """
  Mark the servings ready: flip the flag and touch the ready file at `path`
  (default `#{@default_ready_file}`).
  """
  @spec mark_ready(String.t()) :: :ok
  def mark_ready(path \\ @default_ready_file) do
    :persistent_term.put(@term_key, true)
    File.touch(path)
    :ok
  end
end
