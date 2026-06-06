defmodule Voxd.History do
  @moduledoc """
  Append-only transcription history stored at `~/.local/share/voxd/history.jsonl`.

  Each
  line is `{"ts": <ISO8601 local naive seconds>, "mode": mode, "text": text}`.
  `read/1` returns the last `n` entries; `n <= 0` or a missing file yields an
  empty list and blank lines are skipped.
  """

  @history_path Path.join([
                  System.user_home!(),
                  ".local",
                  "share",
                  "voxd",
                  "history.jsonl"
                ])

  @doc """
  Append one entry to the default history file
  (`~/.local/share/voxd/history.jsonl`).
  """
  @spec append(String.t(), String.t()) :: :ok
  def append(mode, text), do: append(mode, text, @history_path)

  @doc """
  Append one entry to an explicit history file, creating parent directories.
  """
  @spec append(String.t(), String.t(), String.t()) :: :ok
  def append(mode, text, path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, encode_entry(mode, text), [:append])
  end

  @doc """
  Read the last `n` entries from the default history file.
  """
  @spec read(integer()) :: [map()]
  def read(n), do: read(n, @history_path)

  @doc """
  Read the last `n` entries from an explicit history file. `n <= 0` or a
  missing file returns `[]`; blank lines are skipped.
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
