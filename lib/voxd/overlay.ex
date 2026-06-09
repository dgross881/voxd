defmodule Voxd.Overlay do
  @moduledoc """
  Drives the little on-screen status card — the visual feedback that tells
  you voxd is recording, transcribing, or hit an error. A 1:1 port of the
  Python daemon's overlay seam (`daemon.py:95-103`, `overlay.py`).

  This server has two jobs:

    * **Keep the overlay window alive** — it launches the vendored
      `priv/overlay/overlay.py` under `MuonTrap.Daemon`, so the overlay dies
      with voxd and is relaunched if it crashes. The overlay is *optional*:
      with no display (or a broken script) the daemon logs a warning and
      keeps working — you just don't see the card.

    * **Tell the overlay what to show** — by writing one-line messages into
      a named pipe (`/tmp/voxd-overlay.pipe` by default). A typical session
      writes:

          Overlay.show(Overlay, "recording", "dictation")  # card turns on, colored by mode
          Overlay.level(Overlay, 0.42)                     # volume meter moves
          Overlay.show(Overlay, "transcribing")            # spinner state
          Overlay.show(Overlay, "idle")                    # card goes away

      Each call returns `:ok` immediately; the actual pipe write happens in
      the background. The wire format is `state\\n` or `state:text\\n` —
      see `format_message/2` and `format_level/1` for doctested examples.

  ## Why writes shell out instead of using `File.open`

  Opening a named pipe for writing the normal way (`O_WRONLY`) freezes until
  someone is reading the other end — and a process frozen inside that
  `open()` call can't even be killed, which can wedge the whole VM at
  shutdown (verified the hard way). So each write runs a short-lived shell
  command that opens the pipe in read-write mode (`1<>pipe`), which never
  blocks, wrapped in a `timeout` for an upper bound. The server itself never
  blocks, never crashes on a failed write, and silently skips writing when
  the pipe doesn't exist — matching the Python daemon.
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
  Show a bare state on the overlay (e.g. `"transcribing"`, `"idle"`,
  `"cancelled"`). Returns `:ok` immediately; the pipe write happens in the
  background.
  """
  @spec show(GenServer.server(), state()) :: :ok
  def show(server \\ __MODULE__, state), do: show(server, state, "")

  @doc """
  Show a state with extra text. Error text is cut to the first
  #{@error_text_limit} characters so a long crash message can't flood the
  card; `recording` carries the mode so the card can pick its color
  (`recording:ai`, `recording:dictation`).
  """
  @spec show(GenServer.server(), state(), String.t()) :: :ok
  def show(server, state, text) do
    GenServer.call(server, {:write, format_message(state, text)})
  end

  @doc """
  Move the overlay's volume meter. `value` is `0.0` (silence) to `1.0`
  (full); it is written as a `level:<"%.3f">\\n` line.
  """
  @spec level(GenServer.server(), float()) :: :ok
  def level(server \\ __MODULE__, value) do
    GenServer.call(server, {:write, format_level(value)})
  end

  @doc """
  Build one wire-protocol line: `"state\\n"` when `text` is empty, otherwise
  `"state:text\\n"`. Error text is cut to the first #{@error_text_limit}
  characters (Python uses `error:{first 80 chars}`).

      iex> Voxd.Overlay.format_message("idle", "")
      "idle\\n"

      iex> Voxd.Overlay.format_message("recording", "ai")
      "recording:ai\\n"

      iex> message = Voxd.Overlay.format_message("error", String.duplicate("x", 100))
      iex> String.length(message)
      87
  """
  @spec format_message(state(), String.t()) :: String.t()
  def format_message(state, ""), do: state <> "\n"

  def format_message("error", text) do
    "error:" <> truncate(text, @error_text_limit) <> "\n"
  end

  def format_message(state, text), do: state <> ":" <> text <> "\n"

  @doc """
  Build a volume-meter line, always with three decimal places
  (Python `"%.3f"`).

      iex> Voxd.Overlay.format_level(0.5)
      "level:0.500\\n"

      iex> Voxd.Overlay.format_level(0)
      "level:0.000\\n"
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
