defmodule Voxd.Application do
  @moduledoc """
  The voxd OTP application: a `:one_for_one` root supervisor wiring the daemon's
  long-lived processes, plus boot-time lifecycle (pid/ready files, file logger,
  signal handler).

  ## Supervision tree

      Voxd.Supervisor (one_for_one)
      ├── Voxd.ServingSupervisor   (DynamicSupervisor — holds the two Nx.Servings)
      ├── Voxd.Overlay             (GenServer; degrades gracefully with no display)
      ├── Voxd.SessionSup          (Supervisor, rest_for_one)
      │   ├── Voxd.Session         (gen_statem)
      │   └── Voxd.Recorder        (GenServer; non-brutal shutdown — releases mic)
      ├── Voxd.CtlSocket           (permanent accept loop; ready_fun = Ready.ready?)
      └── Voxd.Transcriber.ServingLoader (temporary Task — loads model post-boot)

  The servings are started post-boot by the loader Task (not as static children),
  so the socket accepts connections and reports `"loading"` the whole time the
  model loads and the XLA graphs compile. `SessionSup` is `rest_for_one`: a
  `Session` crash restarts both children (Recorder too); a `Recorder` crash
  restarts only itself, and the `Session`'s monitor (F7) drives the error
  transition.

  ## Test gating

  The full daemon tree must not start in `:test` (tests start each process via
  `start_supervised!`). `start/2` reads `:voxd, :start_daemon?` (default `true`;
  `config/test.exs` sets it `false`) and starts an empty tree in test.
  """

  use Application

  require Logger

  alias Voxd.{CtlSocket, Overlay, Ready, Recorder, Session, SignalHandler}
  alias Voxd.Transcriber.ServingLoader

  @serving_supervisor Voxd.ServingSupervisor
  @session_supervisor Voxd.SessionSup
  @recorder_shutdown_ms 5_000
  @pid_file "/tmp/voxd.pid"
  @log_file "/tmp/voxd.log"

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, term()}
  def start(_type, _args) do
    if start_daemon?() do
      start_daemon()
    end

    Supervisor.start_link(children(), strategy: :one_for_one, name: Voxd.Supervisor)
  end

  @spec start_daemon?() :: boolean()
  defp start_daemon?, do: Application.get_env(:voxd, :start_daemon?, true)

  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  defp children do
    if start_daemon?() do
      daemon_children()
    else
      []
    end
  end

  @spec daemon_children() :: [Supervisor.child_spec() | {module(), term()}]
  defp daemon_children do
    [
      {DynamicSupervisor, strategy: :one_for_one, name: @serving_supervisor},
      {Overlay, name: Overlay},
      session_supervisor_spec(),
      {CtlSocket, ready_fun: &Ready.ready?/0},
      {ServingLoader, supervisor: @serving_supervisor}
    ]
  end

  # rest_for_one: Session before Recorder, so a Session crash restarts Recorder
  # too, while a Recorder crash restarts only Recorder (Session's monitor handles
  # the in-flight recording). The Recorder must release the mic in terminate/2,
  # so its shutdown is a graceful timeout, never :brutal_kill.
  @spec session_supervisor_spec() :: Supervisor.child_spec()
  defp session_supervisor_spec do
    children = [
      {Session, name: Session, recorder: Recorder},
      Supervisor.child_spec({Recorder, name: Recorder}, shutdown: @recorder_shutdown_ms)
    ]

    %{
      id: @session_supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :rest_for_one, name: @session_supervisor]]}
    }
  end

  # --- boot-time lifecycle ---------------------------------------------------

  @spec start_daemon() :: :ok
  defp start_daemon do
    configure_file_logger()
    write_pid_file()
    install_signal_handler()
    :ok
  end

  @spec write_pid_file() :: :ok
  defp write_pid_file do
    File.write(@pid_file, System.pid())
    :ok
  end

  # Keep stdout logging (foreground runs) and add a debug-level file handler so
  # `tail -f /tmp/voxd.log` works under a systemd unit or backgrounded daemon.
  @spec configure_file_logger() :: :ok
  defp configure_file_logger do
    config = %{config: %{file: String.to_charlist(@log_file)}, level: :debug}

    case :logger.add_handler(:voxd_file, :logger_std_h, config) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      {:error, reason} -> Logger.warning("could not add file logger: #{inspect(reason)}")
    end

    :ok
  end

  # SIGTERM runs voxd's cleanup (release mic, idle overlay, remove runtime files,
  # orderly System.stop) instead of the BEAM default init:stop/0.
  #
  # `:os.set_signal/2` on OTP 28 does NOT accept `:sigint` (only sighup/sigquit/
  # sigabrt/sigalrm/sigterm/sigusr1/sigusr2/sigchld/sigstop/sigtstp/sigcont/
  # sigwinch/siginfo); the spec's `set_signal(:sigint, :handle)` would crash boot
  # with `invalid signal name`. We arm only SIGTERM — the signal a systemd unit
  # or `kill` sends — and leave SIGINT to the BEAM's default break handling. The
  # SignalHandler still has a `:sigint` clause for any sigint events the signal
  # server delivers, but we never arm it via set_signal.
  @spec install_signal_handler() :: :ok
  defp install_signal_handler do
    :os.set_signal(:sigterm, :handle)

    :gen_event.swap_sup_handler(
      :erl_signal_server,
      {:erl_signal_handler, []},
      {SignalHandler, []}
    )

    :ok
  end
end
