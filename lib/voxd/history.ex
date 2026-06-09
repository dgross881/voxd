defmodule Voxd.History do
  @moduledoc """
  Keeps a running log of everything voxd has transcribed.

  Every successful dictation is appended as one line to
  `~/.local/share/voxd/history.jsonl`, so `voxctl history` can show your
  recent transcriptions and re-type one on demand. Each line is a small JSON
  record:

      {"ts": "2026-06-07T14:03:21", "mode": "dictation", "text": "hello world "}

  The file is append-only — nothing here ever rewrites or deletes history.
  Reading is forgiving: asking for zero entries, or reading before any
  history exists, just gives you an empty list:

      iex> Voxd.History.read(0, "/nonexistent/history.jsonl")
      []

      iex> Voxd.History.read(5, "/nonexistent/history.jsonl")
      []
  """

  @history_path Path.join([
                  System.user_home!(),
                  ".local",
                  "share",
                  "voxd",
                  "history.jsonl"
                ])

  @doc """
  Record one transcription in the default history file
  (`~/.local/share/voxd/history.jsonl`). The entry is stamped with the
  current local time.
  """
  @spec append(String.t(), String.t()) :: :ok
  def append(mode, text), do: append(mode, text, @history_path)

  @doc """
  Record one transcription in an explicit history file, creating any missing
  parent directories along the way.
  """
  @spec append(String.t(), String.t(), String.t()) :: :ok
  def append(mode, text, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, encode_entry(mode, text), [:append])
  end

  @doc """
  Read the last `n` transcriptions from the default history file, oldest
  first.
  """
  @spec read(integer()) :: [map()]
  def read(n), do: read(n, @history_path)

  @doc """
  Read the last `n` transcriptions from an explicit history file, oldest
  first. Asking for zero or fewer, or reading a file that doesn't exist,
  returns an empty list; blank lines in the file are skipped.
  """
  @spec read(integer(), String.t()) :: [map()]
  def read(n, _path) when n <= 0, do: []

  def read(n, path) do
    case File.read(path) do
      {:ok, contents} -> last_n_entries(contents, n)
      {:error, _reason} -> []
    end
  end

  @spec encode_entry(String.t(), String.t()) :: String.t()
  defp encode_entry(mode, text) do
    JSON.encode!(%{"ts" => now_iso_seconds(), "mode" => mode, "text" => text}) <> "\n"
  end

  @spec now_iso_seconds() :: String.t()
  defp now_iso_seconds do
    NaiveDateTime.local_now()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end

  @spec last_n_entries(String.t(), pos_integer()) :: [map()]
  defp last_n_entries(contents, n) do
    contents
    |> String.split("\n")
    |> Enum.reject(&blank?/1)
    |> Enum.take(-n)
    |> Enum.map(&JSON.decode!/1)
  end

  @spec blank?(String.t()) :: boolean()
  defp blank?(line), do: String.trim(line) == ""
end
