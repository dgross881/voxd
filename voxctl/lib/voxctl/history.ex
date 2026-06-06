defmodule Voxctl.History do
  @moduledoc """
  Reads and renders the transcription history JSONL file from
  `~/.local/share/voxd/history.jsonl` directly — no daemon round-trip.
  A small duplicated reader is acceptable here (the escript is stdlib-only and
  cannot depend on the daemon's `Voxd.History`).
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
  Read the last `n` entries from `path`. `n <= 0` or a missing file returns
  `[]`; blank lines are skipped.
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
  Render the last `n` entries from `path` as the multi-line listing the Python
  ctl prints, or `"No history yet."` when there are none.
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
