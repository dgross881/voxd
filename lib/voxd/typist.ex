defmodule Voxd.Typist do
  @moduledoc """
  Types transcribed text into the focused window, a 1:1 port of the Python
  daemon's typist (`daemon.py:229-253`).

  The sequence is:

    1. `wl-copy --` with the full text on stdin (clipboard fallback for paste).
    2. Sleep 500 ms so window focus settles before the first keystroke.
    3. Split the text on `"\\n"` and, per line, run
       `ydotool type --next-delay 20 --key-delay 20 -- LINE` (empty lines skip
       the `type` call). Between consecutive lines press ENTER with
       `ydotool key KEY_ENTER`; on a nonzero exit retry `ydotool key KEY_RETURN`.

  Every `ydotool` invocation carries `YDOTOOL_SOCKET=/run/user/<uid>/.ydotool_socket`.
  The uid is resolved once via `id -u` and cached.

  The command runner and the sleep function are injectable so tests can assert
  the exact argv sequence without spawning real binaries or waiting 500 ms.
  """

  require Logger

  @type_args ["--next-delay", "20", "--key-delay", "20", "--"]
  @focus_settle_ms 500
  @uid_cache_key {__MODULE__, :uid}

  @typedoc """
  Runs an external command. Same shape as `System.cmd/3`: returns
  `{collected_output, exit_status}`.
  """
  @type runner :: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer()})

  @typedoc "Sleeps for the given number of milliseconds."
  @type sleeper :: (non_neg_integer() -> any())

  @doc """
  Type `text` into the focused window.

  Options:

    * `:runner` — command runner, defaults to `System.cmd/3`.
    * `:sleeper` — sleep function, defaults to `Process.sleep/1`.
  """
  @spec type(String.t(), keyword()) :: :ok
  def type(text, opts \\ []) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    sleeper = Keyword.get(opts, :sleeper, &Process.sleep/1)

    copy_to_clipboard(text, runner)
    sleeper.(@focus_settle_ms)
    type_lines(String.split(text, "\n"), runner)
    :ok
  end

  @spec copy_to_clipboard(String.t(), runner()) :: :ok
  defp copy_to_clipboard(text, runner) do
    runner.("wl-copy", ["--"], input: text)
    :ok
  end

  @spec type_lines([String.t()], runner()) :: :ok
  defp type_lines(lines, runner) do
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.each(fn {line, index} ->
      type_line(line, runner)
      if index < last_index, do: press_enter(runner)
    end)
  end

  @spec type_line(String.t(), runner()) :: :ok
  defp type_line("", _runner), do: :ok

  defp type_line(line, runner) do
    runner.("ydotool", ["type" | @type_args] ++ [line], ydotool_opts())
    :ok
  end

  @spec press_enter(runner()) :: :ok
  defp press_enter(runner) do
    case runner.("ydotool", ["key", "KEY_ENTER"], ydotool_opts()) do
      {_output, 0} -> :ok
      {_output, _nonzero} -> press_return(runner)
    end
  end

  @spec press_return(runner()) :: :ok
  defp press_return(runner) do
    runner.("ydotool", ["key", "KEY_RETURN"], ydotool_opts())
    :ok
  end

  @spec ydotool_opts() :: keyword()
  defp ydotool_opts, do: [env: [{"YDOTOOL_SOCKET", ydotool_socket()}]]

  @spec ydotool_socket() :: String.t()
  defp ydotool_socket, do: "/run/user/#{uid()}/.ydotool_socket"

  @spec uid() :: String.t()
  defp uid do
    case :persistent_term.get(@uid_cache_key, :miss) do
      :miss ->
        resolved = resolve_uid()
        :persistent_term.put(@uid_cache_key, resolved)
        resolved

      cached ->
        cached
    end
  end

  @spec resolve_uid() :: String.t()
  defp resolve_uid do
    {output, 0} = System.cmd("id", ["-u"])
    String.trim(output)
  end
end
