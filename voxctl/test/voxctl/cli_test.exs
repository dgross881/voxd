defmodule Voxctl.CLITest do
  use ExUnit.Case, async: false

  alias Voxctl.CLI

  @moduledoc """
  Ports the command-dispatch cases from the Python `test_ctl.py`: the toggle
  `--mode` flag maps to `toggle:<mode>`, cancel/status send their verb and print
  the reply, `history --copy N` sends `retype:<text>`, and a missing daemon
  yields the error message with exit 1. A fake one-shot Unix-socket daemon
  records the exact line received.
  """

  setup do
    path = short_socket_path()
    on_exit(fn -> File.rm(path) end)
    {:ok, socket_path: path}
  end

  test "toggle with no mode sends toggle:dictation", %{socket_path: socket_path} do
    received = start_fake_daemon(socket_path, "ok")
    assert {"", 0} = CLI.run(["toggle"], socket_path: socket_path)
    assert await_received(received) == "toggle:dictation"
  end

  test "toggle --mode ai sends toggle:ai", %{socket_path: socket_path} do
    received = start_fake_daemon(socket_path, "ok")
    assert {"", 0} = CLI.run(["toggle", "--mode", "ai"], socket_path: socket_path)
    assert await_received(received) == "toggle:ai"
  end

  test "toggle with an invalid mode errors without contacting the daemon", %{
    socket_path: socket_path
  } do
    assert CLI.run(["toggle", "--mode", "bogus"], socket_path: socket_path) ==
             {"Unknown mode: bogus", 1}
  end

  test "cancel sends cancel and returns the reply", %{socket_path: socket_path} do
    received = start_fake_daemon(socket_path, "ok")
    assert {"ok", 0} = CLI.run(["cancel"], socket_path: socket_path)
    assert await_received(received) == "cancel"
  end

  test "status sends status and returns the reply", %{socket_path: socket_path} do
    received = start_fake_daemon(socket_path, "recording")
    assert {"recording", 0} = CLI.run(["status"], socket_path: socket_path)
    assert await_received(received) == "status"
  end

  test "an empty argv prints usage and exits 1" do
    assert {usage, 1} = CLI.run([])
    assert usage =~ "Usage: voxctl"
  end

  test "an unknown command exits 1 with the command name" do
    assert CLI.run(["frobnicate"]) == {"Unknown command: frobnicate", 1}
  end

  test "cancel against a missing daemon reports it is not running", %{socket_path: socket_path} do
    assert CLI.run(["cancel"], socket_path: socket_path) == {"voxd daemon is not running", 1}
  end

  test "status against a missing daemon reports it is not running", %{socket_path: socket_path} do
    assert CLI.run(["status"], socket_path: socket_path) == {"voxd daemon is not running", 1}
  end

  test "toggle against a missing daemon reports it is not running", %{socket_path: socket_path} do
    assert CLI.run(["toggle"], socket_path: socket_path) == {"voxd daemon is not running", 1}
  end

  @tag :tmp_dir
  test "history --copy N sends retype with the entry's text", %{
    socket_path: socket_path,
    tmp_dir: tmp_dir
  } do
    history_path = write_history(tmp_dir, ["first", "second", "third"])
    received = start_fake_daemon(socket_path, "ok")

    assert {"", 0} =
             CLI.run(["history", "--copy", "2"],
               socket_path: socket_path,
               history_path: history_path
             )

    assert await_received(received) == "retype:second"
  end

  @tag :tmp_dir
  test "history --copy with an out-of-range index errors and skips the daemon", %{
    socket_path: socket_path,
    tmp_dir: tmp_dir
  } do
    history_path = write_history(tmp_dir, ["only"])

    assert CLI.run(["history", "--copy", "5"],
             socket_path: socket_path,
             history_path: history_path
           ) == {"No entry #5", 1}
  end

  @tag :tmp_dir
  test "history with no --copy renders the listing", %{tmp_dir: tmp_dir} do
    history_path = write_history(tmp_dir, ["alpha"])

    assert {output, 0} = CLI.run(["history"], history_path: history_path)
    assert output =~ "alpha"
  end

  defp write_history(tmp_dir, texts) do
    path = Path.join(tmp_dir, "history.jsonl")

    lines =
      texts
      |> Enum.map(&%{"ts" => "2026-05-12T09:00:00", "mode" => "dictation", "text" => &1})
      |> Enum.map_join("\n", &JSON.encode!/1)

    File.write!(path, lines <> "\n")
    path
  end

  # Unix sun_path is limited to ~108 bytes, so use a short unique /tmp path.
  defp short_socket_path do
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "voxctl-test-#{unique}.sock")
  end

  defp start_fake_daemon(path, response) do
    test_pid = self()
    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0,
        ifaddr: {:local, to_charlist(path)},
        mode: :binary,
        packet: :line,
        active: false
      )

    spawn_link(fn ->
      {:ok, connection} = :gen_tcp.accept(listen)
      {:ok, line} = :gen_tcp.recv(connection, 0)
      send(test_pid, {:daemon_received, String.trim(line)})
      :gen_tcp.send(connection, response <> "\n")
      :gen_tcp.close(connection)
      :gen_tcp.close(listen)
    end)

    test_pid
  end

  defp await_received(_pid) do
    receive do
      {:daemon_received, line} -> line
    after
      2_000 -> flunk("fake daemon never received a command")
    end
  end
end
