defmodule Voxd.Recorder do
  @moduledoc """
  Owns the `pw-record` capture process and the microphone for the duration of a
  recording only.

  The mic is acquired on `start/0` (spawning `pw-record`) and released on
  `stop/0`/`cancel/0` (killing it). Nothing is captured between recordings, so a
  Bluetooth headset is never held in headset (low-quality SCO) profile while
  idle.

  ## Pull-based capture

  Exile is demand-driven: it never pushes stdout as messages. A dedicated reader
  process loops `Exile.Process.read/2` and `send`s `{:pcm_chunk, binary}` to this
  GenServer, then `{:pcm_eof}` on a clean EOF or `{:pcm_error, reason}` on a read
  error. This GenServer owns the lifecycle: it spawns and tears down both the
  Exile process and the reader.

  ## Warm-up

  A freshly opened Bluetooth SCO link delivers ~1.1 s of digital silence before
  real audio. `start/0` discards leading **all-zero** chunks (silence) until the
  first chunk that contains any non-zero f32 sample — that first live chunk is
  kept as the start of the recording. If only silence arrives before the warm-up
  deadline, the capture is killed and respawned once; if it is still silent after
  the second deadline the recorder proceeds best-effort (keeps collecting).

  ## RMS

  Only the latest chunk is retained for metering; `level/0` computes its raw RMS
  on demand (called at ~150 ms ticks by the Session) rather than per chunk. The
  returned value is the raw RMS — the overlay scaling (`min(1.0, rms * 20)`) is
  the caller's concern.

  ## Mic release (Exile caveat)

  Exile's NIF resource destructor only closes file descriptors; it does **not**
  kill the OS process. The mic is released exclusively via
  `Exile.Process.await_exit/2` (graceful SIGTERM→SIGKILL ladder). This GenServer
  traps exits so `terminate/2` runs and releases the mic on shutdown — the
  supervisor must therefore never `:brutal_kill` it (the child spec sets a
  non-zero `:shutdown`).
  """

  use GenServer

  require Logger

  @default_command ["pw-record", "--rate", "16000", "--channels", "1", "--format", "f32", "-"]
  @read_size 16_384
  @spawn_attempts 3
  @default_spawn_retry_delay_ms 150
  @default_warmup_deadline_ms 1_500
  @await_exit_timeout_ms 2_000
  @sample_rate 16_000
  @bytes_per_sample 4

  defstruct command: @default_command,
            warmup_deadline_ms: @default_warmup_deadline_ms,
            spawn_retry_delay_ms: @default_spawn_retry_delay_ms,
            proc: nil,
            reader: nil,
            chunks: [],
            latest_chunk: nil,
            recording?: false,
            eof?: false

  @typedoc "RMS amplitude of the latest captured chunk (raw, unscaled)."
  @type level :: float()

  @doc """
  Start the recorder GenServer.

  Options:
    * `:name` — registered name (default `#{inspect(__MODULE__)}`).
    * `:command` — argv list run in place of `pw-record` (default the
      `pw-record` capture command); injected so tests substitute stub binaries.
    * `:warmup_deadline_ms` — per-attempt warm-up budget (default
      `#{@default_warmup_deadline_ms}`).
    * `:spawn_retry_delay_ms` — delay between spawn attempts (default
      `#{@default_spawn_retry_delay_ms}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquire the mic: spawn the capture process and run warm-up.

  Returns `:ok` once the capture is live (or best-effort after warm-up fails to
  see audio). Returns `{:error, :no_input_device}` if the capture binary cannot
  be spawned after #{@spawn_attempts} attempts.
  """
  @spec start(GenServer.server()) :: :ok | {:error, :no_input_device}
  def start(server \\ __MODULE__) do
    GenServer.call(server, :start, :infinity)
  end

  @doc """
  Release the mic and return the recording.

  Returns `{:ok, pcm}` with all captured chunks concatenated in capture order
  (warm-up silence excluded), or `{:error, :not_recording}` if no capture was
  started.
  """
  @spec stop(GenServer.server()) :: {:ok, binary()} | {:error, :not_recording}
  def stop(server \\ __MODULE__) do
    GenServer.call(server, :stop, :infinity)
  end

  @doc """
  Release the mic and discard the recording. Always `:ok`, even when idle.
  """
  @spec cancel(GenServer.server()) :: :ok
  def cancel(server \\ __MODULE__) do
    GenServer.call(server, :cancel, :infinity)
  end

  @doc """
  Raw RMS amplitude of the latest captured chunk, `0.0` when nothing captured.

  Scaling for display (`min(1.0, rms * 20)`) is the caller's concern.
  """
  @spec level(GenServer.server()) :: level()
  def level(server \\ __MODULE__) do
    GenServer.call(server, :level)
  end

  @doc """
  Whether a capture is currently live (started and not yet at EOF/error).
  """
  @spec recording?(GenServer.server()) :: boolean()
  def recording?(server \\ __MODULE__) do
    GenServer.call(server, :recording?)
  end

  @doc """
  The last `seconds` of captured audio as a raw f32 binary.

  Used by the Session's watcher tick to transcribe a short trailing window
  without stopping the recording. The window is byte-aligned to whole f32
  samples (4 bytes); a window longer than the capture returns the whole
  capture, and an empty capture returns `<<>>`.
  """
  @spec tail(GenServer.server(), float()) :: binary()
  def tail(server \\ __MODULE__, seconds) do
    GenServer.call(server, {:tail, seconds})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, struct!(__MODULE__, opts)}
  end

  @impl true
  def handle_call(:start, _from, %__MODULE__{recording?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:start, _from, state) do
    case acquire(state) do
      {:ok, acquired_state} -> {:reply, :ok, acquired_state}
      {:error, :no_input_device} -> {:reply, {:error, :no_input_device}, reset(state)}
    end
  end

  def handle_call(:stop, _from, %__MODULE__{proc: nil} = state) do
    {:reply, {:error, :not_recording}, state}
  end

  def handle_call(:stop, _from, state) do
    {:reply, {:ok, captured_audio(state)}, release(state)}
  end

  def handle_call(:cancel, _from, %__MODULE__{proc: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, release(state)}
  end

  def handle_call(:level, _from, state) do
    {:reply, rms(state.latest_chunk), state}
  end

  def handle_call(:recording?, _from, state) do
    {:reply, state.recording?, state}
  end

  def handle_call({:tail, seconds}, _from, state) do
    {:reply, tail_window(state, seconds), state}
  end

  @impl true
  def handle_info({:pcm_chunk, chunk}, %__MODULE__{recording?: true} = state) do
    {:noreply, append_chunk(state, chunk)}
  end

  def handle_info({:pcm_eof}, state) do
    {:noreply, %{state | recording?: false, eof?: true}}
  end

  def handle_info({:pcm_error, reason}, state) do
    Logger.warning("recorder read error: #{inspect(reason)}")
    {:noreply, %{state | recording?: false, eof?: true}}
  end

  # A late chunk that lost the race with stop/cancel: proc already gone, drop it.
  def handle_info({:pcm_chunk, _chunk}, state), do: {:noreply, state}

  # Reader process exit and trapped EXITs are expected during teardown.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Exile delivers the external program's exit status to the owner as
  # `{exit_ref, status}`; we read audio via the reader, so this is informational.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: release(state)

  # --- acquisition -----------------------------------------------------------

  @spec acquire(t()) :: {:ok, t()} | {:error, :no_input_device}
  defp acquire(state) do
    case spawn_capture(state, @spawn_attempts) do
      {:ok, spawned} -> {:ok, warm_up(spawned)}
      {:error, :no_input_device} = error -> error
    end
  end

  @spec spawn_capture(t(), non_neg_integer()) :: {:ok, t()} | {:error, :no_input_device}
  defp spawn_capture(_state, 0), do: {:error, :no_input_device}

  defp spawn_capture(state, attempts_left) do
    case Exile.Process.start_link(state.command, stderr: :disable) do
      {:ok, proc} ->
        reader = start_reader(proc, self())
        :ok = Exile.Process.change_pipe_owner(proc, :stdout, reader)
        send(reader, :read_now)
        {:ok, %{state | proc: proc, reader: reader, recording?: true, eof?: false}}

      {:error, _reason} ->
        Process.sleep(state.spawn_retry_delay_ms)
        spawn_capture(state, attempts_left - 1)
    end
  end

  # Reader loop: blocking reads converted into messages for the owner. Linked so
  # the owner tears it down when the Exile process is killed.
  #
  # Only the stdout pipe owner may `read/2`. The recorder transfers stdout
  # ownership to this process, then signals `:read_now`; the reader waits for
  # that signal before its first read so it never reads before it owns the pipe.
  @spec start_reader(Exile.Process.t(), pid()) :: pid()
  defp start_reader(proc, owner) do
    spawn_link(fn ->
      receive do
        :read_now -> read_loop(proc, owner)
      end
    end)
  end

  @spec read_loop(Exile.Process.t(), pid()) :: :ok
  defp read_loop(proc, owner) do
    case Exile.Process.read(proc, @read_size) do
      {:ok, pcm} ->
        send(owner, {:pcm_chunk, IO.iodata_to_binary(pcm)})
        read_loop(proc, owner)

      :eof ->
        send(owner, {:pcm_eof})

      {:error, reason} ->
        send(owner, {:pcm_error, reason})
    end
  end

  # --- warm-up ---------------------------------------------------------------

  # Discard leading all-zero (silent) chunks until the first live chunk, which is
  # kept as the start of the recording. On deadline with only silence: respawn
  # once; if still silent, proceed best-effort.
  @spec warm_up(t()) :: t()
  defp warm_up(state) do
    deadline = System.monotonic_time(:millisecond) + state.warmup_deadline_ms

    case await_live_chunk(state, deadline) do
      {:live, live_state} -> live_state
      :silent -> respawn_and_warm_up(state)
    end
  end

  @spec respawn_and_warm_up(t()) :: t()
  defp respawn_and_warm_up(state) do
    respawned = release_capture(state)

    case spawn_capture(respawned, 1) do
      {:ok, spawned} -> proceed_best_effort(spawned)
      {:error, :no_input_device} -> reset(respawned)
    end
  end

  @spec proceed_best_effort(t()) :: t()
  defp proceed_best_effort(state) do
    deadline = System.monotonic_time(:millisecond) + state.warmup_deadline_ms

    case await_live_chunk(state, deadline) do
      {:live, live_state} -> live_state
      :silent -> state
    end
  end

  # Block (owner-side) for the next chunk until the deadline, discarding silent
  # chunks. `{:live, state}` once a non-silent chunk arrives (kept); `:silent` if
  # the deadline passes (or EOF) with only silence.
  @spec await_live_chunk(t(), integer()) :: {:live, t()} | :silent
  defp await_live_chunk(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive_chunk_or_timeout(state, remaining, deadline)
  end

  @spec receive_chunk_or_timeout(t(), integer(), integer()) :: {:live, t()} | :silent
  defp receive_chunk_or_timeout(_state, remaining, _deadline) when remaining <= 0, do: :silent

  defp receive_chunk_or_timeout(state, remaining, deadline) do
    receive do
      {:pcm_chunk, chunk} -> classify_warmup_chunk(state, chunk, deadline)
      {:pcm_eof} -> :silent
      {:pcm_error, _reason} -> :silent
    after
      remaining -> :silent
    end
  end

  @spec classify_warmup_chunk(t(), binary(), integer()) :: {:live, t()} | :silent
  defp classify_warmup_chunk(state, chunk, deadline) do
    case silent_chunk?(chunk) do
      true -> await_live_chunk(state, deadline)
      false -> {:live, append_chunk(state, chunk)}
    end
  end

  # --- teardown --------------------------------------------------------------

  @spec release(t()) :: t()
  defp release(state) do
    state |> release_capture() |> reset()
  end

  @spec release_capture(t()) :: t()
  defp release_capture(%__MODULE__{proc: nil} = state), do: state

  defp release_capture(state) do
    await_exit(state.proc)
    %{state | proc: nil, reader: nil}
  end

  # `await_exit/2` runs the SIGTERM→SIGKILL ladder and reaps the OS process. It
  # may exit (rather than raise) if the Exile process is already gone — that
  # still means the mic is released, so both outcomes are treated as success.
  @spec await_exit(Exile.Process.t()) :: :ok
  defp await_exit(proc) do
    Exile.Process.await_exit(proc, @await_exit_timeout_ms)
    :ok
  catch
    kind, reason ->
      Logger.debug("recorder await_exit #{kind}: #{inspect(reason)}")
      :ok
  end

  @spec reset(t()) :: t()
  defp reset(state) do
    %{
      state
      | proc: nil,
        reader: nil,
        chunks: [],
        latest_chunk: nil,
        recording?: false,
        eof?: false
    }
  end

  # --- chunks / RMS ----------------------------------------------------------

  @spec append_chunk(t(), binary()) :: t()
  defp append_chunk(state, chunk) do
    %{state | chunks: [chunk | state.chunks], latest_chunk: chunk}
  end

  @spec captured_audio(t()) :: binary()
  defp captured_audio(state) do
    state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # The trailing `seconds` of the in-order capture, byte-aligned to whole f32
  # samples. A window at least as long as the capture returns the whole capture.
  @spec tail_window(t(), float()) :: binary()
  defp tail_window(state, seconds) do
    audio = captured_audio(state)
    take_last_bytes(audio, window_bytes(seconds))
  end

  @spec window_bytes(float()) :: non_neg_integer()
  defp window_bytes(seconds) do
    trunc(seconds * @sample_rate) * @bytes_per_sample
  end

  @spec take_last_bytes(binary(), non_neg_integer()) :: binary()
  defp take_last_bytes(audio, want) when byte_size(audio) <= want, do: audio

  defp take_last_bytes(audio, want) do
    binary_part(audio, byte_size(audio) - want, want)
  end

  # A chunk is silent when every f32 sample is exactly zero (digital silence from
  # the SCO warm-up). Any non-zero sample means the mic is live.
  @spec silent_chunk?(binary()) :: boolean()
  defp silent_chunk?(chunk) do
    Enum.all?(for(<<s::float-32-native <- chunk>>, do: s), &(&1 == 0.0))
  end

  @spec rms(binary() | nil) :: float()
  defp rms(nil), do: 0.0

  defp rms(chunk) do
    samples = for <<s::float-32-native <- chunk>>, do: s
    rms_of_samples(samples)
  end

  @spec rms_of_samples([float()]) :: float()
  defp rms_of_samples([]), do: 0.0

  defp rms_of_samples(samples) do
    sum_of_squares = Enum.reduce(samples, 0.0, fn s, acc -> acc + s * s end)
    :math.sqrt(sum_of_squares / length(samples))
  end

  @typedoc false
  @type t :: %__MODULE__{}
end
