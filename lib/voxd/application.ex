defmodule Voxd.Application do
  @moduledoc """
  Boots voxd and keeps every part of it alive.

  This is the application's root: it starts each long-lived process in
  order, restarts whatever crashes, and handles the boot-time chores
  (pid file, log file, signal handler).

  ## Who supervises whom

      Voxd.Supervisor (one_for_one)
      ├── Voxd.ServingSupervisor   (holds the two speech-model servings)
      ├── Voxd.Overlay             (the on-screen card; optional without a display)
      ├── Voxd.SessionSup          (rest_for_one)
      │   ├── Voxd.Session         (the state machine — the daemon's heart)
      │   └── Voxd.Recorder        (the mic; gets a graceful shutdown, never brutal)
      ├── Voxd.CtlSocket           (the voxctl socket; permanent — always restarted)
      ├── Voxd.Transcriber.ServingLoader (one-shot background model loader)
      └── Voxd.Hotkey              (press-and-hold key; only if [hotkey] enabled)

  Two deliberate choices in that shape:

    * **The model loads after boot, not during.** The servings are started
      by the loader Task rather than as static children, so the control
      socket answers (`"loading"`) the whole time the model loads and
      compiles. The daemon is responsive within a second of starting.

    * **Session and Recorder restart together — but only in one direction.**
      `rest_for_one` with Session first means a Session crash also restarts
      the Recorder (no orphaned mic capture), while a Recorder crash
      restarts only the Recorder — the Session is watching it and turns the
      loss into an error overlay instead of dying too. And the Recorder's
      shutdown is a graceful timeout, never `:brutal_kill`, because it must
      release the microphone in `terminate/2`.

  ## Test gating

  The full daemon tree must not start in `:test` (tests start each process
  themselves via `start_supervised!`). `start/2` reads `:voxd,
  :start_daemon?` (default `true`; `config/test.exs` sets it `false`) and
  starts an empty tree in test.
  """

  use Application

  require Logger

  alias Voxd.{Config, CtlSocket, Hotkey, Overlay, Ready, Recorder, Session, SignalHandler}
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
    ] ++ hotkey_child()
  end

  # The press-and-hold hotkey is opt-in: only started when config.toml has
  # `[hotkey] enabled = true`. Started after Session so the toggle target exists.
  @spec hotkey_child() :: [{module(), keyword()}]
  defp hotkey_child do
    case Config.load()["hotkey"] do
      %{"enabled" => true} = hotkey_config -> [{Hotkey, hotkey_opts(hotkey_config)}]
      _ -> []
    end
  end

  @spec hotkey_opts(map()) :: keyword()
  defp hotkey_opts(hotkey_config) do
    [
      device_name: hotkey_config["device_name"],
      keycode: hotkey_config["keycode"],
      hold_ms: hotkey_config["hold_ms"],
      mode: hotkey_config["mode"]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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
