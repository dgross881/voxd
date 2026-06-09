defmodule Voxd.Hotkey do
  @moduledoc """
  A press-and-hold hotkey, read straight from the keyboard at the evdev layer.

  GNOME's keyboard shortcuts fire the instant a key goes down and know nothing
  about how long it's held; Wayland also forbids ordinary apps from grabbing
  global hotkeys. So to get a "hold for a moment to start dictating" gesture,
  voxd reads the input device itself — below the compositor — and times the
  hold on its own.

  The deal is simple: hold the configured key down for at least `:hold_ms`
  (default 1 s) and voxd toggles a recording, exactly as if you'd pressed your
  `voxctl toggle` shortcut. A quick tap does nothing, so the key keeps its
  normal job — only a deliberate hold triggers voxd.

  ## How it reads the keyboard

  A linked reader process opens the input device (resolved by **name**, since
  the `/dev/input/eventN` number is not stable across replugs) and loops on
  24-byte evdev frames, mailing each key event to this server as
  `{:key, code, value}` (`value` is `1` down, `0` up). Two constraints learned
  the hard way:

    * the reader must *open the device in its own process* — a raw file
      descriptor may only be read by the process that opened it; and
    * voxd must read the device that actually carries the key. With
      input-remapper in the path that is its *forwarded* device, because
      input-remapper grabs the physical keyboard exclusively.

  Reading `/dev/input/*` needs the running user to be in the `input` group.

  ## The hold, as a tiny state machine

      key down  → start a `:hold_ms` timer
      key up    → cancel the timer (released too soon — a tap, ignored)
      timer fires while still held → run the toggle, once

  No auto-repeat is assumed: the gesture rests entirely on a clean down/up pair
  plus the timer.

  ## Robustness

  If the device can't be found (input-remapper not up yet) or vanishes
  mid-stream, the reader reports `{:reader_error, reason}` and the server
  reschedules a fresh read after `:retry_ms` rather than crashing — so voxd
  survives the keyboard being unplugged or input-remapper restarting.

  ## Configuration

  Off unless enabled. `Voxd.Application` starts this server only when
  `config.toml` has `[hotkey] enabled = true`; the section also carries
  `device_name`, `keycode`, `hold_ms`, and `mode`. See
  `priv/config.toml.example`.
  """

  use GenServer

  require Logger

  alias Voxd.Session

  @event_size 24
  @ev_key 1
  @default_keycode 464
  @default_hold_ms 1_000
  @default_retry_ms 3_000

  defstruct [:keycode, :hold_ms, :retry_ms, :reader, :toggle_fun, :timer, held?: false]

  @typedoc false
  @type t :: %__MODULE__{}

  @doc """
  Start the hotkey server.

  Options:

    * `:name` — registered name (default `#{inspect(__MODULE__)}`); `nil`
      starts it unregistered (tests).
    * `:device_name` — exact `/sys/class/input/eventN/device/name` to read.
    * `:keycode` — evdev key code to watch (default `#{@default_keycode}`,
      `KEY_FN`).
    * `:hold_ms` — how long the key must be held to fire (default
      `#{@default_hold_ms}`).
    * `:mode` — mode passed to `Voxd.Session.toggle/1` (default
      `"dictation"`).
    * `:retry_ms` — pause before re-opening the device after a read error
      (default `#{@default_retry_ms}`).
    * `:toggle_fun` — zero-argument effect run on a completed hold (default
      toggles `Voxd.Session` in `:mode`); injected in tests.
    * `:reader` — one-argument function given the server pid, responsible for
      starting the key-event stream; default opens the real device. Tests pass
      a no-op so no `/dev/input` access happens.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, t(), {:continue, :start_reader}}
  def init(opts) do
    {:ok, build_state(opts), {:continue, :start_reader}}
  end

  @spec build_state(keyword()) :: t()
  defp build_state(opts) do
    keycode = Keyword.get(opts, :keycode, @default_keycode)
    mode = Keyword.get(opts, :mode, "dictation")
    device_name = Keyword.get(opts, :device_name)

    %__MODULE__{
      keycode: keycode,
      hold_ms: Keyword.get(opts, :hold_ms, @default_hold_ms),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
      reader: Keyword.get(opts, :reader, fn owner -> start_reader(owner, device_name) end),
      toggle_fun: Keyword.get(opts, :toggle_fun, fn -> Session.toggle(mode) end)
    }
  end

  @impl GenServer
  def handle_continue(:start_reader, state) do
    state.reader.(self())
    {:noreply, state}
  end

  @impl GenServer
  # Key down on the watched key, not already held: arm the hold timer.
  def handle_info({:key, code, 1}, %{keycode: code, held?: false} = state) do
    timer = Process.send_after(self(), :hold_elapsed, state.hold_ms)
    {:noreply, %{state | held?: true, timer: timer}}
  end

  # Key up on the watched key: released — cancel a still-pending hold (a tap).
  def handle_info({:key, code, 0}, %{keycode: code} = state) do
    cancel_timer(state.timer)
    {:noreply, %{state | held?: false, timer: nil}}
  end

  # The hold completed while the key is still down: fire the toggle once.
  def handle_info(:hold_elapsed, %{held?: true} = state) do
    state.toggle_fun.()
    {:noreply, %{state | timer: nil}}
  end

  # The device dropped out: log and re-open after a pause instead of crashing.
  def handle_info({:reader_error, reason}, state) do
    Logger.debug("hotkey reader error: #{inspect(reason)}; retrying in #{state.retry_ms}ms")
    Process.send_after(self(), :start_reader, state.retry_ms)
    {:noreply, state}
  end

  def handle_info(:start_reader, state) do
    state.reader.(self())
    {:noreply, state}
  end

  # Other keys, repeats, a stale `:hold_elapsed` after release: nothing to do.
  def handle_info(_message, state), do: {:noreply, state}

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  # --- evdev reader ----------------------------------------------------------

  # Link the reader so a crash restarts the whole server (and re-resolves the
  # device). The reader opens the device in its own process — a raw fd may only
  # be read by its opener — and streams `{:key, code, value}` to the owner.
  @spec start_reader(pid(), String.t() | nil) :: pid()
  defp start_reader(owner, device_name) do
    spawn_link(fn -> open_and_read(owner, device_name) end)
  end

  @spec open_and_read(pid(), String.t() | nil) :: :ok
  defp open_and_read(owner, device_name) do
    case resolve_device(device_name) do
      nil -> send_reader_error(owner, :device_not_found)
      path -> open_path(owner, path)
    end
  end

  @spec open_path(pid(), String.t()) :: :ok
  defp open_path(owner, path) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, fd} -> read_loop(fd, owner)
      {:error, reason} -> send_reader_error(owner, reason)
    end
  end

  @spec read_loop(File.io_device(), pid()) :: :ok
  defp read_loop(fd, owner) do
    case :file.read(fd, @event_size) do
      {:ok,
       <<_sec::little-64, _usec::little-64, type::little-16, code::little-16,
         value::little-signed-32>>} ->
        if type == @ev_key, do: send(owner, {:key, code, value})
        read_loop(fd, owner)

      :eof ->
        send_reader_error(owner, :eof)

      {:error, reason} ->
        send_reader_error(owner, reason)
    end
  end

  @spec send_reader_error(pid(), term()) :: :ok
  defp send_reader_error(owner, reason) do
    send(owner, {:reader_error, reason})
    :ok
  end

  # Resolve a device by its kernel name, since the eventN number is not stable.
  @spec resolve_device(String.t() | nil) :: String.t() | nil
  defp resolve_device(nil), do: nil

  defp resolve_device(device_name) do
    "/sys/class/input/event*"
    |> Path.wildcard()
    |> Enum.find_value(fn sys_dir -> match_device(sys_dir, device_name) end)
  end

  @spec match_device(String.t(), String.t()) :: String.t() | nil
  defp match_device(sys_dir, device_name) do
    case File.read(Path.join(sys_dir, "device/name")) do
      {:ok, name} ->
        if String.trim(name) == device_name, do: "/dev/input/#{Path.basename(sys_dir)}"

      _ ->
        nil
    end
  end
end
