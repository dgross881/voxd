defmodule Voxctl.Client do
  @moduledoc """
  The wire between `voxctl` and the daemon: a tiny one-shot socket client,
  ported 1:1 from the Python `ctl.send_command`.

  Each call is one complete conversation: connect to the daemon's socket
  (default `/tmp/voxd.sock`, overridable via the `VOXD_SOCKET` environment
  variable or an explicit path), send one command line, read one reply
  line, hang up, and return the reply trimmed:

      Client.send_command("status", "/tmp/voxd.sock")
      #=> {:ok, "idle"}

  If the daemon isn't running, connecting fails and you get
  `{:error, :daemon_down}` — which the CLI turns into a friendly message.
  """

  @default_path "/tmp/voxd.sock"

  @doc """
  Resolve the socket path: the `VOXD_SOCKET` environment variable if set,
  else `/tmp/voxd.sock`.
  """
  @spec default_path() :: String.t()
  def default_path, do: System.get_env("VOXD_SOCKET", @default_path)

  @doc """
  Send `command` to the daemon at `path` and return `{:ok, reply}` with the
  trimmed reply line, or `{:error, :daemon_down}` if the socket can't be
  reached.
  """
  @spec send_command(String.t(), String.t()) :: {:ok, String.t()} | {:error, :daemon_down}
  def send_command(command, path) do
    case connect(path) do
      {:ok, socket} -> send_and_receive(socket, command)
      {:error, _reason} -> {:error, :daemon_down}
    end
  end

  @spec connect(String.t()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  defp connect(path) do
    :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, packet: :line, active: false])
  end

  @spec send_and_receive(:gen_tcp.socket(), String.t()) ::
          {:ok, String.t()} | {:error, :daemon_down}
  defp send_and_receive(socket, command) do
    :ok = :gen_tcp.send(socket, command <> "\n")

    reply =
      case :gen_tcp.recv(socket, 0) do
        {:ok, line} -> {:ok, String.trim(line)}
        {:error, _reason} -> {:error, :daemon_down}
      end

    :gen_tcp.close(socket)
    reply
  end
end
