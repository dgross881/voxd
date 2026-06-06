defmodule Voxd.CtlSocket do
  @moduledoc """
  Unix-domain control socket for the daemon, ported 1:1 from the Python
  `daemon.py` control loop and `ctl.py` client.

  Binds `/tmp/voxd.sock` (overridable) with a line protocol and serves one
  connection at a time from a single accept loop, exactly like the Python
  daemon. Each connection is one-shot: the client sends one command line, the
  socket dispatches it, replies `response <> "\\n"`, and closes.

  ## Protocol

  | Command         | Dispatch                                            |
  |-----------------|-----------------------------------------------------|
  | `toggle`        | `session.toggle("dictation")`                       |
  | `toggle:MODE`   | `session.toggle(MODE)` (Session returns `"unknown"` for a bad mode) |
  | `cancel`        | `session.cancel()`                                  |
  | `status`        | `"loading"` until serving is ready, else `session.status()` |
  | `retype:TEXT`   | `session.retype(TEXT)` (colons inside TEXT preserved) |
  | anything else   | `"unknown"`                                         |

  ## Injection

  The Session module and the serving-readiness predicate are injectable so the
  socket can be tested without the real `Voxd.Session` existing. `:session`
  defaults to `Voxd.Session` (a bare module atom, so it need not be loaded at
  compile time) and `:ready_fun` defaults to `fn -> true end` (Task 13 wires
  the real readiness check).
  """

  require Logger

  @default_path "/tmp/voxd.sock"

  @doc """
  Child spec for supervision. The accept loop runs as a permanent child (F7):
  if it ever exits the supervisor restarts it.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Start the accept loop in a linked process. Options: `:path` (socket path,
  default `/tmp/voxd.sock`), `:session` (Session module, default
  `Voxd.Session`), `:ready_fun` (0-arity predicate, default `fn -> true end`).
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    path = Keyword.get(opts, :path, @default_path)
    session = Keyword.get(opts, :session, Voxd.Session)
    ready_fun = Keyword.get(opts, :ready_fun, fn -> true end)

    {:ok, spawn_link(fn -> listen_and_serve(path, session, ready_fun) end)}
  end

  @spec listen_and_serve(String.t(), module(), (-> boolean())) :: no_return()
  defp listen_and_serve(path, session, ready_fun) do
    File.rm(path)
    {:ok, listen_socket} = open_listen_socket(path)
    accept_loop(listen_socket, session, ready_fun)
  end

  @spec open_listen_socket(String.t()) :: {:ok, :gen_tcp.socket()}
  defp open_listen_socket(path) do
    :gen_tcp.listen(0,
      ifaddr: {:local, to_charlist(path)},
      mode: :binary,
      packet: :line,
      active: false
    )
  end

  @spec accept_loop(:gen_tcp.socket(), module(), (-> boolean())) :: no_return()
  defp accept_loop(listen_socket, session, ready_fun) do
    {:ok, connection} = :gen_tcp.accept(listen_socket)
    serve_connection(connection, session, ready_fun)
    accept_loop(listen_socket, session, ready_fun)
  end

  @spec serve_connection(:gen_tcp.socket(), module(), (-> boolean())) :: :ok
  defp serve_connection(connection, session, ready_fun) do
    case :gen_tcp.recv(connection, 0) do
      {:ok, line} ->
        reply = dispatch(String.trim_trailing(line, "\n"), session, ready_fun)
        :gen_tcp.send(connection, reply <> "\n")

      {:error, reason} ->
        Logger.debug("voxd ctl socket read error: #{inspect(reason)}")
    end

    :gen_tcp.close(connection)
  end

  @spec dispatch(String.t(), module(), (-> boolean())) :: String.t()
  defp dispatch("toggle", session, _ready_fun), do: session.toggle("dictation")
  defp dispatch("toggle:" <> mode, session, _ready_fun), do: session.toggle(mode)
  defp dispatch("cancel", session, _ready_fun), do: session.cancel()
  defp dispatch("status", session, ready_fun), do: status(session, ready_fun)
  defp dispatch("retype:" <> text, session, _ready_fun), do: session.retype(text)
  defp dispatch(_other, _session, _ready_fun), do: "unknown"

  @spec status(module(), (-> boolean())) :: String.t()
  defp status(session, ready_fun) do
    if ready_fun.() do
      session.status()
    else
      "loading"
    end
  end
end
