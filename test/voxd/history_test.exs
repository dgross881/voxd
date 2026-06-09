defmodule Voxd.HistoryTest do
  use ExUnit.Case, async: true

  alias Voxd.History

  doctest Voxd.History

  @iso_seconds ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/

  @tag :tmp_dir
  test "append then read round-trips one entry", %{tmp_dir: tmp_dir} do
    path = history_path(tmp_dir)

    History.append("dictation", "hello world", path)

    assert [entry] = History.read(1, path)
    assert entry["mode"] == "dictation"
    assert entry["text"] == "hello world"
  end

  @tag :tmp_dir
  test "append creates the parent directory", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "nested", "deeper", "history.jsonl"])

    History.append("ai", "note", path)

    assert File.exists?(path)
  end

  @tag :tmp_dir
  test "read(n) returns the last n entries in order", %{tmp_dir: tmp_dir} do
    path = history_path(tmp_dir)

    for text <- ["one", "two", "three", "four"], do: History.append("dictation", text, path)

    texts = 2 |> History.read(path) |> Enum.map(& &1["text"])

    assert texts == ["three", "four"]
  end

  @tag :tmp_dir
  test "missing file returns an empty list", %{tmp_dir: tmp_dir} do
    assert History.read(5, history_path(tmp_dir)) == []
  end

  @tag :tmp_dir
  test "n <= 0 returns an empty list", %{tmp_dir: tmp_dir} do
    path = history_path(tmp_dir)
    History.append("dictation", "present", path)

    assert History.read(0, path) == []
    assert History.read(-3, path) == []
  end

  @tag :tmp_dir
  test "blank lines are skipped", %{tmp_dir: tmp_dir} do
    path = history_path(tmp_dir)
    History.append("dictation", "kept", path)
    File.write!(path, "\n   \n", [:append])

    assert [entry] = History.read(10, path)
    assert entry["text"] == "kept"
  end

  @tag :tmp_dir
  test "timestamp is ISO8601 to the second with no timezone", %{tmp_dir: tmp_dir} do
    path = history_path(tmp_dir)
    History.append("dictation", "x", path)

    [entry] = History.read(1, path)

    assert Regex.match?(@iso_seconds, entry["ts"])
  end

  @spec history_path(String.t()) :: String.t()
  defp history_path(tmp_dir), do: Path.join(tmp_dir, "history.jsonl")
end
