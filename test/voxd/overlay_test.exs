defmodule Voxd.OverlayTest do
  use ExUnit.Case, async: true

  alias Voxd.Overlay

  doctest Voxd.Overlay

  describe "format_message/2 (pure protocol formatting)" do
    test "state with no text renders 'state\\n'" do
      assert Overlay.format_message("transcribing", "") == "transcribing\n"
    end

    test "state with text renders 'state:text\\n'" do
      assert Overlay.format_message("recording", "ai") == "recording:ai\n"
    end

    test "error text is truncated to the first 80 characters" do
      long = String.duplicate("x", 200)
      line = Overlay.format_message("error", long)
      assert line == "error:" <> String.duplicate("x", 80) <> "\n"
    end

    test "an 80-char error is not truncated and an 81-char one loses one char" do
      exactly_80 = String.duplicate("a", 80)
      assert Overlay.format_message("error", exactly_80) == "error:" <> exactly_80 <> "\n"

      over = String.duplicate("a", 81)
      assert Overlay.format_message("error", over) == "error:" <> exactly_80 <> "\n"
    end
  end

  describe "format_level/1 (pure level formatting)" do
    test "formats with three decimals like Python '%.3f'" do
      assert Overlay.format_level(0.5) == "level:0.500\n"
    end

    test "rounds to three decimals" do
      assert Overlay.format_level(0.123456) == "level:0.123\n"
    end

    test "formats whole numbers with trailing zeros" do
      assert Overlay.format_level(1.0) == "level:1.000\n"
      assert Overlay.format_level(0.0) == "level:0.000\n"
    end
  end

  describe "FIFO writes with a reader attached" do
    @tag :tmp_dir
    test "show/2 message arrives at the reader", %{tmp_dir: tmp_dir} do
      pipe = Path.join(tmp_dir, "overlay.pipe")
      make_fifo!(pipe)

      reader = start_reader(pipe)

      {:ok, overlay} = start_overlay(pipe)
      Overlay.show(overlay, "recording", "dictation")

      assert read_arrived?(reader, "recording:dictation\n")
      stop_reader(reader)
    end

    @tag :tmp_dir
    test "level/2 message arrives at the reader", %{tmp_dir: tmp_dir} do
      pipe = Path.join(tmp_dir, "overlay.pipe")
      make_fifo!(pipe)

      reader = start_reader(pipe)

      {:ok, overlay} = start_overlay(pipe)
      Overlay.level(overlay, 0.25)

      assert read_arrived?(reader, "level:0.250\n")
      stop_reader(reader)
    end
  end

  describe "FIFO with no reader" do
    @tag :tmp_dir
    test "show/2 returns immediately and never crashes the GenServer", %{tmp_dir: tmp_dir} do
      pipe = Path.join(tmp_dir, "overlay.pipe")
      make_fifo!(pipe)

      {:ok, overlay} = start_overlay(pipe)

      {micros, :ok} = :timer.tc(fn -> Overlay.show(overlay, "transcribing") end)
      assert micros < 300_000

      assert Process.alive?(overlay)
      assert :pong == GenServer.call(overlay, :ping)
    end
  end

  describe "missing FIFO path" do
    @tag :tmp_dir
    test "writing to a non-existent pipe does not crash", %{tmp_dir: tmp_dir} do
      pipe = Path.join(tmp_dir, "does-not-exist.pipe")
      refute File.exists?(pipe)

      {:ok, overlay} = start_overlay(pipe)
      assert :ok == Overlay.show(overlay, "idle")

      assert Process.alive?(overlay)
      assert :pong == GenServer.call(overlay, :ping)
    end
  end

  defp start_overlay(pipe) do
    start_supervised(
      {Overlay, name: nil, pipe_path: pipe, supervise_process: false},
      restart: :temporary
    )
  end

  defp make_fifo!(path) do
    {_out, 0} = System.cmd("mkfifo", [path])
    :ok
  end

  # `cat PIPE` blocks at the OS level (not in a BEAM async thread, which would
  # wedge shutdown) and streams the FIFO to a killable port.
  defp start_reader(pipe) do
    Port.open({:spawn_executable, System.find_executable("cat")}, [
      :binary,
      :exit_status,
      args: [pipe]
    ])
  end

  defp read_arrived?(port, expected, deadline_ms \\ 2_000) do
    receive do
      {^port, {:data, ^expected}} -> true
    after
      deadline_ms -> false
    end
  end

  # The reader `cat` exits on its own when the writer closes the FIFO (EOF), so
  # the port may die between any liveness check and the close — closing a dead
  # port raises ArgumentError. Treat it as already stopped.
  defp stop_reader(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
