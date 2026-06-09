defmodule Voxd.CtlSocketTest do
  use ExUnit.Case, async: false

  alias Voxd.CtlSocket

  @moduledoc """
  Drives a real Unix-domain socket against a stub Session module. Each test
  starts a `CtlSocket` bound to a tmp path, then connects a client, sends one
  line, and asserts the framed reply (and, where relevant, which Session
  function the socket dispatched to).
  """

  defmodule StubSession do
    @moduledoc false

    def toggle(mode), do: notify_and_reply({:toggle, mode}, "toggle:#{mode}")
    def cancel, do: notify_and_reply(:cancel, "ok")
    def status, do: notify_and_reply(:status, status_reply())
    def retype(text), do: notify_and_reply({:retype, text}, "ok")

    defp notify_and_reply(message, reply) do
      send(test_pid(), {:session_called, message})
      reply
    end

    defp status_reply, do: :persistent_term.get({__MODULE__, :status_reply}, "idle")
    defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
  end

  setup do
    :persistent_term.put({StubSession, :test_pid}, self())
    :persistent_term.put({StubSession, :status_reply}, "idle")
    path = short_socket_path()
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  # Unix-domain socket paths are limited to ~108 bytes (sun_path), so the long
  # ExUnit :tmp_dir paths overflow. Use a short, unique path under /tmp instead.
  defp short_socket_path do
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "voxd-ctl-test-#{unique}.sock")
  end

  test "toggle with no mode dispatches dictation", %{path: path} do
    start_socket(path)
    assert send_line(path, "toggle") == "toggle:dictation"
    assert_receive {:session_called, {:toggle, "dictation"}}
  end

  test "toggle:ai passes the explicit mode through", %{path: path} do
    start_socket(path)
    assert send_line(path, "toggle:ai") == "toggle:ai"
    assert_receive {:session_called, {:toggle, "ai"}}
  end

  test "toggle with an unknown mode passes the mode to the Session unchanged", %{path: path} do
    start_socket(path)
    assert send_line(path, "toggle:bogus") == "toggle:bogus"
    assert_receive {:session_called, {:toggle, "bogus"}}
  end

  test "cancel dispatches to Session.cancel", %{path: path} do
    start_socket(path)
    assert send_line(path, "cancel") == "ok"
    assert_receive {:session_called, :cancel}
  end

  test "status returns the Session status when serving is ready", %{path: path} do
    :persistent_term.put({StubSession, :status_reply}, "recording")
    start_socket(path, ready_fun: fn -> true end)
    assert send_line(path, "status") == "recording"
    assert_receive {:session_called, :status}
  end

  test "status returns loading and skips the Session while serving is not ready", %{path: path} do
    start_socket(path, ready_fun: fn -> false end)
    assert send_line(path, "status") == "loading"
    refute_receive {:session_called, :status}
  end

  test "retype passes the text after the first colon", %{path: path} do
    start_socket(path)
    assert send_line(path, "retype:hello world") == "ok"
    assert_receive {:session_called, {:retype, "hello world"}}
  end

  test "retype preserves colons inside the text", %{path: path} do
    start_socket(path)
    assert send_line(path, "retype:a:b") == "ok"
    assert_receive {:session_called, {:retype, "a:b"}}
  end

  test "retype preserves interior whitespace and only trims the trailing newline", %{path: path} do
    start_socket(path)
    assert send_line(path, "retype:  spaced  text  ") == "ok"
    assert_receive {:session_called, {:retype, "  spaced  text  "}}
  end

  test "an unknown command replies unknown without calling the Session", %{path: path} do
    start_socket(path)
    assert send_line(path, "frobnicate") == "unknown"
    refute_receive {:session_called, _}
  end

  test "two sequential connections are both served by the serial accept loop", %{path: path} do
    start_socket(path)
    assert send_line(path, "cancel") == "ok"
    assert send_line(path, "status") == "idle"
    assert_receive {:session_called, :cancel}
    assert_receive {:session_called, :status}
  end

  test "an existing socket file at the path is removed before binding", %{path: path} do
    File.write!(path, "stale")
    start_socket(path)
    assert send_line(path, "cancel") == "ok"
  end

  # No poll-for-socket helper: CtlSocket.start_link opens the listen socket
  # synchronously before returning, so start_supervised! only returns once the
  # socket is bound. If that guarantee ever regresses, these tests fail outright
  # (connection refused) instead of being masked by a retry loop.
  defp start_socket(path, opts \\ []) do
    opts = Keyword.merge([path: path, session: StubSession], opts)
    start_supervised!({CtlSocket, opts})
  end

  defp send_line(path, command) do
    {:ok, socket} =
      :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, packet: :line, active: false])

    :ok = :gen_tcp.send(socket, command <> "\n")
    {:ok, line} = :gen_tcp.recv(socket, 0)
    :gen_tcp.close(socket)
    String.trim_trailing(line, "\n")
  end
end
