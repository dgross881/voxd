defmodule Voxd.Overlay do
  @moduledoc """
  Drives the on-screen overlay, a 1:1 port of the Python daemon's overlay seam
  (`daemon.py:95-103`, `overlay.py`).

  Two responsibilities:

    * **Process supervision** — launches the vendored `priv/overlay/overlay.py`
      under `MuonTrap.Daemon` so the overlay dies with voxd and is restarted if
      it exits. The overlay is *optional*: if it cannot be launched the daemon
      logs and keeps running.

    * **Protocol writes** — writes single-line messages to the overlay FIFO
      (`/tmp/voxd-overlay.pipe` by default). The wire protocol is `state\\n` or
      `state:text\\n`; recording carries the mode (`recording:dictation`), and
      audio level is `level:<"%.3f">`.

  Opening a FIFO for writing with `O_WRONLY` blocks until a reader attaches and,
  worse, a process stuck in that `open()` syscall cannot be killed — it can wedge
  BEAM shutdown. So writes go through a short-lived `Task` that shells out and
  opens the pipe `O_RDWR` (`1<>pipe`), which never blocks on a missing reader.
  The `timeout` wrapper bounds the lifetime. The GenServer itself never blocks,
  never crashes on a write failure, and silently skips when the pipe is missing —
  matching `daemon.py:95-103`.
  """

  use GenServer

  require Logger

  @default_pipe_path "/tmp/voxd-overlay.pipe"
  @default_command ["python3"]
  @error_text_limit 80
  @write_timeout_s "0.5"
  @restart_delay_ms 1_000

  defstruct [:pipe_path]

  @typedoc "Overlay protocol state token written before the optional `:text`."
  @type state :: String.t()

  @doc """
  Start the overlay GenServer.

  Options:

    * `:name` — registered name (default `Voxd.Overlay`); pass `nil` for an
      unregistered instance (tests).
    * `:pipe_path` — overlay FIFO path (default `#{@default_pipe_path}`).
    * `:supervise_process` — when `true` (default), launch and supervise
      `overlay.py`. Tests pass `false` to exercise the FIFO logic without a
      display.
    * `:command` — argv prefix used to launch the script
      (default `#{inspect(@default_command)}`); the script path is appended.
    * `:overlay_script` — path to the overlay script (default
      `priv/overlay/overlay.py` resolved from the app's priv dir).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Write a bare `state\\n` line to the overlay (e.g. `"transcribing"`, `"idle"`,
  `"cancelled"`). Returns `:ok` immediately; the write happens off-process.
  """
  @spec show(GenServer.server(), state()) :: :ok
  def show(server \\ __MODULE__, state), do: show(server, state, "")

  @doc """
  Write a `state:text\\n` line. `error` text is truncated to the first
  #{@error_text_limit} characters; `recording` carries the mode for card colour
  (`recording:ai`, `recording:dictation`).
  """
  @spec show(GenServer.server(), state(), String.t()) :: :ok
  def show(server, state, text) do
    GenServer.call(server, {:write, format_message(state, text)})
  end

  @doc """
  Write a `level:<"%.3f">\\n` line for the audio meter.
  """
  @spec level(GenServer.server(), float()) :: :ok
  def level(server \\ __MODULE__, value) do
    GenServer.call(server, {:write, format_level(value)})
  end

  @doc """
  Format a protocol message: `"state\\n"` when `text` is empty, otherwise
  `"state:text\\n"`. `error` text is truncated to the first #{@error_text_limit}
  characters (Python uses `error:{first 80 chars}`).

      iex> Voxd.Overlay.format_message("idle", "")
      "idle\\n"

      iex> Voxd.Overlay.format_message("recording", "ai")
      "recording:ai\\n"
  """
  @spec format_message(state(), String.t()) :: String.t()
  def format_message(state, ""), do: state <> "\n"

  def format_message("error", text) do
    "error:" <> truncate(text, @error_text_limit) <> "\n"
  end

  def format_message(state, text), do: state <> ":" <> text <> "\n"

  @doc """
  Format an audio level line as `level:<"%.3f">\\n` (Python `"%.3f"`).

      iex> Voxd.Overlay.format_level(0.5)
      "level:0.500\\n"
  """
  @spec format_level(float()) :: String.t()
  def format_level(value) do
    "level:" <> :erlang.float_to_binary(value * 1.0, decimals: 3) <> "\n"
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{pipe_path: Keyword.get(opts, :pipe_path, @default_pipe_path)}

    if Keyword.get(opts, :supervise_process, true) do
      launch_overlay(opts)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:write, line}, _from, state) do
    spawn_pipe_writer(state.pipe_path, line)
    {:reply, :ok, state}
  end

  def handle_call(:ping, _from, state), do: {:reply, :pong, state}

  @impl GenServer
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.debug("overlay process exited (#{inspect(reason)}); restarting")
    Process.send_after(self(), :relaunch, @restart_delay_ms)
    {:noreply, state}
  end

  def handle_info(:relaunch, state) do
    launch_overlay([])
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec launch_overlay(keyword()) :: :ok
  defp launch_overlay(opts) do
    [executable | leading_args] = Keyword.get(opts, :command, @default_command)
    args = leading_args ++ [overlay_script(opts)]

    case MuonTrap.Daemon.start_link(executable, args, log_output: :debug) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "overlay process could not start (#{inspect(reason)}); continuing without overlay"
        )

        :ok
    end
  end

  @spec overlay_script(keyword()) :: String.t()
  defp overlay_script(opts) do
    Keyword.get_lazy(opts, :overlay_script, fn ->
      Path.join([:code.priv_dir(:voxd), "overlay", "overlay.py"])
    end)
  end

  @spec spawn_pipe_writer(String.t(), String.t()) :: :ok
  defp spawn_pipe_writer(pipe_path, line) do
    Task.start(fn -> write_to_pipe(pipe_path, line) end)
    :ok
  end

  @spec write_to_pipe(String.t(), String.t()) :: :ok
  defp write_to_pipe(pipe_path, line) do
    if File.exists?(pipe_path) do
      shell_write(pipe_path, line)
    else
      :ok
    end
  end

  @spec shell_write(String.t(), String.t()) :: :ok
  defp shell_write(pipe_path, line) do
    System.cmd(
      "timeout",
      ["-s", "KILL", @write_timeout_s, "sh", "-c", redirect_script(), "--", line],
      env: [{"PIPE", pipe_path}],
      stderr_to_stdout: true
    )

    :ok
  rescue
    error ->
      Logger.debug("overlay pipe write failed: #{inspect(error)}")
      :ok
  end

  @spec redirect_script() :: String.t()
  defp redirect_script do
    # `1<>"$PIPE"` opens the FIFO O_RDWR so the write never blocks on a missing
    # reader; the line is the sole positional arg (`$1`) and the path comes via
    # the `PIPE` env var so neither is subject to shell word-splitting.
    ~s(printf %s "$1" 1<>"$PIPE")
  end

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(text, limit), do: String.slice(text, 0, limit)
end
