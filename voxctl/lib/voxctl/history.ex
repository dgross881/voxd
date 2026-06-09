defmodule Voxctl.History do
  @moduledoc """
  Shows your transcription history for `voxctl history` — read straight
  from the history file, no need for the daemon to even be running.

  Reads `~/.local/share/voxd/history.jsonl` (the file the daemon appends
  to) and renders it as a numbered listing:

        1  14:03  [dictation]  hello world
        2  14:05  [ai]  The meeting moved to Thursday.

  When there's no history yet, you get told exactly that:

      iex> Voxctl.History.render(20, "/nonexistent/history.jsonl")
      "No history yet."

  This module intentionally duplicates the daemon's small JSONL reader:
  the escript is stdlib-only and can't depend on `Voxd.History`.
  """

  @history_path Path.join([
                  System.user_home!(),
                  ".local",
                  "share",
                  "voxd",
                  "history.jsonl"
                ])

  @doc """
  Default history file path (`~/.local/share/voxd/history.jsonl`).
  """
  @spec default_path() :: String.t()
  def default_path, do: @history_path

  @doc """
  Read the last `n` entries from `path`, oldest first. Asking for zero or
  fewer, or reading a file that doesn't exist, returns an empty list; blank
  lines are skipped.

      iex> Voxctl.History.read(5, "/nonexistent/history.jsonl")
      []
  """
  @spec read(integer(), String.t()) :: [map()]
  def read(n, _path) when n <= 0, do: []

  def read(n, path) do
    case File.read(path) do
      {:ok, contents} -> last_n_entries(contents, n)
      {:error, _reason} -> []
    end
  end

  @doc """
  Render the last `n` entries from `path` as the numbered listing shown in
  the module docs (the same format the Python ctl printed), or
  `"No history yet."` when there are none.
  """
  @spec render(integer(), String.t()) :: String.t()
  def render(n, path) do
    case read(n, path) do
      [] -> "No history yet."
      entries -> entries |> Enum.with_index(1) |> Enum.map_join("\n", &render_line/1)
    end
  end

  @spec last_n_entries(String.t(), integer()) :: [map()]
  defp last_n_entries(contents, n) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&JSON.decode!/1)
    |> Enum.take(-n)
  end

  @spec render_line({map(), pos_integer()}) :: String.t()
  defp render_line({entry, index}) do
    number = index |> to_string() |> String.pad_leading(3)
    hh_mm = hh_mm(entry["ts"])
    "#{number}  #{hh_mm}  [#{entry["mode"]}]  #{entry["text"]}"
  end

  @spec hh_mm(String.t()) :: String.t()
  defp hh_mm(ts), do: String.slice(ts, 11, 5)
end
