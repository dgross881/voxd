defmodule Voxd.Ready do
  @moduledoc """
  Answers one question: has the speech model finished loading yet?

  The Whisper model takes several seconds to load and compile at startup.
  Until it's ready, `voxctl status` says `"loading"`; the moment the loader
  finishes and calls `mark_ready/1`, status flips to `"idle"` and the file
  `/tmp/voxd-ready` appears — so a script can also just check for the file
  instead of asking the socket.

  The flag lives in `:persistent_term`, which makes reading it essentially
  free no matter how often the control socket asks. It starts out `false`
  on every boot.
  """

  @term_key {__MODULE__, :ready?}
  @default_ready_file "/tmp/voxd-ready"

  @doc """
  The `:persistent_term` key the readiness flag is stored under. Exposed so
  tests can reset state between cases.
  """
  @spec term_key() :: {module(), :ready?}
  def term_key, do: @term_key

  @doc """
  The default ready-file path (`#{@default_ready_file}`).
  """
  @spec default_ready_file() :: String.t()
  def default_ready_file, do: @default_ready_file

  @doc """
  Whether the speech model is loaded and ready to transcribe. `false` until
  `mark_ready/1` runs.
  """
  @spec ready?() :: boolean()
  def ready?, do: :persistent_term.get(@term_key, false)

  @doc """
  Declare the model ready: flip the flag and create the ready file at `path`
  (default `#{@default_ready_file}`).
  """
  @spec mark_ready(String.t()) :: :ok
  def mark_ready(path \\ @default_ready_file) do
    :persistent_term.put(@term_key, true)
    File.touch(path)
    :ok
  end
end
