defmodule Voxctl.HistoryTest do
  use ExUnit.Case, async: true

  alias Voxctl.History

  @moduledoc """
  Ports the history rendering cases from the Python `test_ctl.py`: empty file,
  entry rendering, ordering of the last `n`, and the `HH:MM` timestamp slice.
  """

  setup %{tmp_dir: tmp_dir} do
    {:ok, path: Path.join(tmp_dir, "history.jsonl")}
  end

  @tag :tmp_dir
  test "render of a missing file is the empty marker", %{path: path} do
    assert History.render(20, path) == "No history yet."
  end

  @tag :tmp_dir
  test "render of an empty file is the empty marker", %{path: path} do
    File.write!(path, "")
    assert History.render(20, path) == "No history yet."
  end

  @tag :tmp_dir
  test "render shows the text, mode, and HH:MM slice of an entry", %{path: path} do
    write_entries(path, [entry("2026-05-12T11:51:03", "dictation", "Hello world")])

    rendered = History.render(20, path)

    assert rendered =~ "Hello world"
    assert rendered =~ "[dictation]"
    assert rendered =~ "11:51"
    refute rendered =~ ":03"
  end

  @tag :tmp_dir
  test "render numbers entries from 1 with right-aligned width 3", %{path: path} do
    write_entries(path, [
      entry("2026-05-12T09:00:00", "ai", "first"),
      entry("2026-05-12T09:01:00", "dictation", "second")
    ])

    assert History.render(20, path) == "  1  09:00  [ai]  first\n  2  09:01  [dictation]  second"
  end

  @tag :tmp_dir
  test "render returns only the last n entries in file order", %{path: path} do
    write_entries(path, [
      entry("2026-05-12T09:00:00", "dictation", "oldest"),
      entry("2026-05-12T09:01:00", "dictation", "middle"),
      entry("2026-05-12T09:02:00", "dictation", "newest")
    ])

    rendered = History.render(2, path)

    refute rendered =~ "oldest"
    assert rendered == "  1  09:01  [dictation]  middle\n  2  09:02  [dictation]  newest"
  end

  @tag :tmp_dir
  test "read skips blank lines", %{path: path} do
    File.write!(path, "\n" <> JSON.encode!(entry("2026-05-12T09:00:00", "ai", "x")) <> "\n\n")

    assert [%{"text" => "x"}] = History.read(20, path)
  end

  @tag :tmp_dir
  test "read with n <= 0 returns no entries", %{path: path} do
    write_entries(path, [entry("2026-05-12T09:00:00", "ai", "x")])
    assert History.read(0, path) == []
  end

  defp write_entries(path, entries) do
    File.write!(path, Enum.map_join(entries, "\n", &JSON.encode!/1) <> "\n")
  end

  defp entry(ts, mode, text), do: %{"ts" => ts, "mode" => mode, "text" => text}
end

defmodule Voxctl.HistoryDocTest do
  use ExUnit.Case, async: true

  # Separate module: the doctests need no setup, while Voxctl.HistoryTest's
  # setup pattern-matches on the :tmp_dir tag that doctests don't carry.
  doctest Voxctl.History
end
