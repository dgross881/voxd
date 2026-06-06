defmodule Voxctl.CLI do
  @moduledoc """
  Command-line entry point for `voxctl`, the standalone control client, ported
  1:1 from the Python `linux-voice-ctl` (`ctl.py`).

  Subcommands: `toggle [--mode dictation|ai]`, `cancel`, `status`, and
  `history [--n N] [--copy N]`. `run/1` is pure-ish — it returns
  `{output, exit_code}` so the behaviour is testable without `System.halt/1`;
  `main/1` is a thin wrapper that prints the output to the right stream and
  halts. Output on exit 0 goes to stdout, on a non-zero exit to stderr (matching
  ctl.py, where every error path writes to stderr and exits 1).

  Socket path defaults to `/tmp/voxd.sock` (`VOXD_SOCKET` overrides); the
  history file defaults to `~/.local/share/linux-voice/history.jsonl`. Both are
  overridable via opts for testing.
  """

  alias Voxctl.Client
  alias Voxctl.History

  @usage "Usage: voxctl <toggle [--mode dictation|ai] | cancel | status | history [--n N] [--copy N]>"
  @daemon_down "voxd daemon is not running"
  @valid_modes ~w(dictation ai)

  @doc """
  Escript entry point. Runs the parsed command, prints its output to stdout
  (exit 0) or stderr (non-zero), and halts with the exit code.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    {output, exit_code} = run(argv)
    print_output(output, exit_code)
    System.halt(exit_code)
  end

  @doc """
  Run the parsed command and return `{output, exit_code}`. `opts` may override
  `:socket_path` and `:history_path` (used by tests); they default to the
  daemon socket and the shared history file.
  """
  @spec run([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def run(argv, opts \\ [])
  def run([], _opts), do: {@usage, 1}
  def run(["toggle" | rest], opts), do: toggle(rest, opts)
  def run(["cancel" | _rest], opts), do: reply_command("cancel", opts)
  def run(["status" | _rest], opts), do: reply_command("status", opts)
  def run(["history" | rest], opts), do: history(rest, opts)
  def run([command | _rest], _opts), do: {"Unknown command: #{command}", 1}

  @spec toggle([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  defp toggle(args, opts) do
    mode = flag_value(args, "--mode", "dictation")

    if mode in @valid_modes do
      send_silent("toggle:#{mode}", opts)
    else
      {"Unknown mode: #{mode}", 1}
    end
  end

  @spec reply_command(String.t(), keyword()) :: {String.t(), non_neg_integer()}
  defp reply_command(command, opts) do
    case Client.send_command(command, socket_path(opts)) do
      {:ok, reply} -> {reply, 0}
      {:error, :daemon_down} -> {@daemon_down, 1}
    end
  end

  @spec send_silent(String.t(), keyword()) :: {String.t(), non_neg_integer()}
  defp send_silent(command, opts) do
    case Client.send_command(command, socket_path(opts)) do
      {:ok, _reply} -> {"", 0}
      {:error, :daemon_down} -> {@daemon_down, 1}
    end
  end

  @spec history([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  defp history(args, opts) do
    n = args |> flag_value("--n", "20") |> String.to_integer()

    case flag_value(args, "--copy", nil) do
      nil -> {History.render(n, history_path(opts)), 0}
      copy -> copy_entry(String.to_integer(copy), n, opts)
    end
  end

  @spec copy_entry(integer(), integer(), keyword()) :: {String.t(), non_neg_integer()}
  defp copy_entry(copy_index, n, opts) do
    entries = History.read(n, history_path(opts))

    case entry_text(entries, copy_index) do
      {:ok, text} -> send_silent("retype:#{text}", opts)
      {:error, message} -> {message, 1}
    end
  end

  @spec entry_text([map()], integer()) :: {:ok, String.t()} | {:error, String.t()}
  defp entry_text(entries, copy_index) when copy_index < 1 or copy_index > length(entries),
    do: {:error, "No entry ##{copy_index}"}

  defp entry_text(entries, copy_index), do: {:ok, Enum.at(entries, copy_index - 1)["text"]}

  @spec flag_value([String.t()], String.t(), String.t() | nil) :: String.t() | nil
  defp flag_value(args, flag, default) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> default
      index -> Enum.at(args, index + 1, default)
    end
  end

  @spec socket_path(keyword()) :: String.t()
  defp socket_path(opts), do: Keyword.get_lazy(opts, :socket_path, &Client.default_path/0)

  @spec history_path(keyword()) :: String.t()
  defp history_path(opts), do: Keyword.get_lazy(opts, :history_path, &History.default_path/0)

  @spec print_output(String.t(), non_neg_integer()) :: :ok
  defp print_output("", _exit_code), do: :ok
  defp print_output(output, 0), do: IO.puts(output)
  defp print_output(output, _exit_code), do: IO.puts(:stderr, output)
end
