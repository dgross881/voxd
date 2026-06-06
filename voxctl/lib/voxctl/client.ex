defmodule Voxctl.Client do
  @moduledoc """
  Unix-domain socket client for the voxd control protocol, ported 1:1 from the
  Python `ctl.send_command`.

  Opens a one-shot connection to the daemon socket (default `/tmp/voxd.sock`,
  overridable via the `VOXD_SOCKET` env var or an explicit path), sends
  `command <> "\\n"`, reads one reply line, and returns it trimmed. A failure to
  connect (daemon down) returns `{:error, :daemon_down}`.
  """

  @default_path "/tmp/voxd.sock"

  @doc """
  Resolve the socket path: the `VOXD_SOCKET` env var if set, else
  `/tmp/voxd.sock`.
  """
  @spec default_path() :: String.t()
  def default_path, do: System.get_env("VOXD_SOCKET", @default_path)

  @doc """
  Send `command` to the daemon at `path` and return its trimmed reply, or
  `{:error, :daemon_down}` if the socket cannot be reached.
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
