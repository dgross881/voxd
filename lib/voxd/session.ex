defmodule Voxd.Session do
  @moduledoc """
  The daemon's heart: tracks where we are in the record → transcribe → type
  cycle and reacts to every button press, timer tick, and crash along the way.

  One hard rule shapes everything here: **the Session never waits on anything
  slow.** Transcription (the GPU), the AI cleanup call, and the typing delay
  all run in background Tasks. The Session only reacts to their results, so a
  `voxctl toggle` always gets an instant answer no matter what's in flight.

  ## The four states, as a user experiences them

      :idle → :acquiring → :recording → :transcribing → back to :idle

  **`:idle` — waiting for you.** `toggle/2` answers `"ok"` immediately, shows
  the recording card, and starts grabbing the microphone in the background.

      Session.toggle("dictation")   #=> "ok"   (card appears, mic is warming up)

  **`:acquiring` — grabbing the mic.** Takes about a second on Bluetooth.
  Success starts the volume-meter and stop-phrase timers and recording is
  live; failure shows "No input device" and returns to `:idle`. Pressing
  toggle again here is acknowledged but ignored — you can't double-start.
  `cancel/1` aborts the grab and frees the mic.

  **`:recording` — capturing your voice.** Two timers run:

    * every 150 ms the volume meter on the overlay is updated;
    * every 1 s a background Task transcribes the last 2 seconds of audio,
      listening for a spoken stop phrase ("end recording", "done", …). A
      match acts exactly like pressing toggle. Ticks never overlap: while
      one watcher Task is still running (the GPU pass takes ~1.2 s, longer
      than the tick), the next tick is skipped.

  Pressing toggle stops the recorder: a take shorter than 0.3 s is rejected
  with "Recording too short"; anything longer heads to `:transcribing`. If
  the recorder process dies mid-take, the Session notices (it's monitoring),
  shows an error, and returns to `:idle`.

  **`:transcribing` — turning speech into text.** The pipeline Task (below)
  is running in the background. When it finishes, back to `:idle`. If it
  crashes, the error shows on the overlay and the session still recovers to
  `:idle` — a bad take never wedges the daemon. Pressing toggle here starts
  a brand-new recording right away (matching the Python daemon); the
  in-flight transcription keeps going and types its text when done.
  `cancel/1` does nothing — transcription can't be canceled.

  ## The pipeline Task

  The full background journey of one take: transcribe the audio → clean up
  the text (`PostProcess.run/1`) → if nothing usable was heard, show
  "Nothing heard" and stop (no history entry, nothing typed) → otherwise,
  for `"ai"` mode ask Ollama to polish the text → save to history → type it
  into the focused window.

  ## Status, from the outside

      Session.status()              #=> "recording" (while acquiring/recording)
      Session.status()              #=> "idle"      (while idle or transcribing)
      Session.retype("hello ")      #=> "ok"        (types saved text, no recording)

  ## Dependency injection

  Every collaborator is injectable so tests can substitute stubs/fakes:

    * `:recorder` — the recorder server (pid or name) the Session monitors
      and calls; default `Voxd.Recorder`.
    * `:recorder_mod` — module whose functions (`start/1`, `stop/1`,
      `cancel/1`, `level/1`, `tail/2`) take the server first; default
      `Voxd.Recorder`.
    * `:overlay_show` / `:overlay_level` — overlay effect functions.
    * `:typist_paste`, `:ai_cleanup`, `:history_append`, `:config_load` —
      pipeline effect functions.
    * `:level_interval_ms` / `:watcher_interval_ms` — timer intervals
      (made tiny in tests).

  The transcriber module comes from `Application.fetch_env!(:voxd,
  :transcriber)` (`Voxd.Transcriber.Mock` in tests). The Session passes
  `serving: :final` / `serving: :watcher`; resolving those names to processes
  is the transcriber's concern.

  Every state transition above is asserted in `test/voxd/session_test.exs`.
  """

  @behaviour :gen_statem

  require Logger

  alias Voxd.{Overlay, PostProcess, Recorder, Typist}

  @min_audio_bytes 19_200
  @watcher_window_seconds 2.0
  # 0.5 s minimum tail = 8000 samples × 4 bytes.
  @watcher_min_bytes 32_000
  @default_level_interval_ms 150
  @default_watcher_interval_ms 1_000
  @valid_modes ~w(dictation ai)

  defstruct [
    :recorder,
    :recorder_mod,
    :recorder_ref,
    :overlay_show,
    :overlay_level,
    :typist_paste,
    :ai_cleanup,
    :history_append,
    :config_load,
    :level_interval_ms,
    :watcher_interval_ms,
    :mode,
    :acquire_task,
    :watcher_task,
    :pipeline_ref
  ]

  @typedoc false
  @type data :: %__MODULE__{}

  # --- public API ------------------------------------------------------------

  @doc """
  Start the Session state machine. See the module docs for the injectable
  options. A `:name` of `nil` starts it unregistered (tests); otherwise it
  registers under `:name` (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    start_statem(name, opts)
  end

  @doc """
  Child spec for a supervisor. The Session is a worker started via `start_link/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @spec start_statem(atom() | nil, keyword()) :: :gen_statem.start_ret()
  defp start_statem(nil, opts), do: :gen_statem.start_link(__MODULE__, opts, [])

  defp start_statem(name, opts) do
    :gen_statem.start_link({:local, name}, __MODULE__, opts, [])
  end

  @doc """
  The main button: start a recording, or stop one that's running.

  `mode` is `"dictation"` (type exactly what you said) or `"ai"` (polish the
  text through Ollama first). Returns `"ok"` for a valid mode — what happens
  next depends on the current state, see the module docs — or `"unknown"`
  for anything else, with no state change.
  """
  @spec toggle(String.t()) :: String.t()
  def toggle(mode), do: toggle(__MODULE__, mode)

  @spec toggle(:gen_statem.server_ref(), String.t()) :: String.t()
  def toggle(server, mode) when mode in @valid_modes do
    :gen_statem.call(server, {:toggle, mode})
  end

  def toggle(_server, _mode), do: "unknown"

  @doc """
  Abandon the current recording (or mic grab) and throw the audio away.
  Always answers `"ok"`, even when there's nothing to cancel.
  """
  @spec cancel() :: String.t()
  def cancel, do: cancel(__MODULE__)

  @spec cancel(:gen_statem.server_ref()) :: String.t()
  def cancel(server), do: :gen_statem.call(server, :cancel)

  @doc """
  What the daemon is doing right now: `"recording"` while grabbing the mic
  or capturing, `"idle"` otherwise. Note that transcribing reports `"idle"`
  too — matching the Python daemon, where status flips to idle the moment
  recording stops.
  """
  @spec status() :: String.t()
  def status, do: status(__MODULE__)

  @spec status(:gen_statem.server_ref()) :: String.t()
  def status(server), do: :gen_statem.call(server, :status)

  @doc """
  Type `text` into the focused window exactly as given — no recording, no
  clean-up, no history entry, no AI (matching the Python retype handler).
  Used by `voxctl history --copy N` to re-type an old transcription. Works
  in any state and always answers `"ok"`.
  """
  @spec retype(String.t()) :: String.t()
  def retype(text), do: retype(__MODULE__, text)

  @spec retype(:gen_statem.server_ref(), String.t()) :: String.t()
  def retype(server, text), do: :gen_statem.call(server, {:retype, text})

  # --- callbacks -------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(opts) do
    # Trap exits: the acquire/watcher/pipeline Tasks are linked (Task.async), so
    # a task crash would otherwise take the Session down before its monitor
    # `:DOWN` could be handled. The stray `{:EXIT, _, _}` is ignored; the `:DOWN`
    # drives the error transition.
    Process.flag(:trap_exit, true)
    {:ok, :idle, build_data(opts)}
  end

  @spec build_data(keyword()) :: data()
  defp build_data(opts) do
    recorder = Keyword.get(opts, :recorder, Recorder)

    %__MODULE__{
      recorder: recorder,
      recorder_mod: Keyword.get(opts, :recorder_mod, Recorder),
      overlay_show: Keyword.get(opts, :overlay_show, &default_overlay_show/2),
      overlay_level: Keyword.get(opts, :overlay_level, &default_overlay_level/1),
      typist_paste: Keyword.get(opts, :typist_paste, &Typist.type/1),
      ai_cleanup: Keyword.get(opts, :ai_cleanup, &default_ai_cleanup/2),
      history_append: Keyword.get(opts, :history_append, &default_history_append/2),
      config_load: Keyword.get(opts, :config_load, &Voxd.Config.load/0),
      level_interval_ms: Keyword.get(opts, :level_interval_ms, @default_level_interval_ms),
      watcher_interval_ms: Keyword.get(opts, :watcher_interval_ms, @default_watcher_interval_ms)
    }
  end

  # The server argument is explicit: Overlay.show/2 is show(server \\ __MODULE__,
  # state), so Overlay.show(state, text) would bind `state` as the server —
  # the daemon's first live toggle crashed exactly that way.
  defp default_overlay_show(state, text), do: Overlay.show(Overlay, state, text)
  defp default_overlay_level(value), do: Overlay.level(Overlay, value)
  defp default_ai_cleanup(text, config), do: Voxd.AI.cleanup(text, config)
  defp default_history_append(mode, text), do: Voxd.History.append(mode, text)

  # --- :idle -----------------------------------------------------------------

  @doc false
  def idle({:call, from}, {:toggle, mode}, data) do
    overlay(data, "recording", mode)
    started = start_acquire(data, mode)
    {:next_state, :acquiring, started, [{:reply, from, "ok"}]}
  end

  def idle({:call, from}, :cancel, _data), do: {:keep_state_and_data, [{:reply, from, "ok"}]}
  def idle({:call, from}, :status, _data), do: {:keep_state_and_data, [{:reply, from, "idle"}]}
  def idle({:call, from}, {:retype, text}, data), do: handle_retype(from, text, data)
  def idle(:info, _message, _data), do: :keep_state_and_data

  # --- :acquiring ------------------------------------------------------------

  @doc false
  # Acquire succeeded: start metering + watcher and begin recording.
  def acquiring(:info, {ref, :ok}, %{acquire_task: %{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {recording, actions} = start_recording(data)
    {:next_state, :recording, recording, actions}
  end

  def acquiring(:info, {ref, {:error, :no_input_device}}, %{acquire_task: %{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    overlay(data, "error", "No input device")
    {:next_state, :idle, clear_acquire(data)}
  end

  def acquiring(:info, {:DOWN, ref, :process, _pid, reason}, %{acquire_task: %{ref: ref}} = data) do
    Logger.warning("acquire task crashed: #{inspect(reason)}")
    overlay(data, "error", "No input device")
    {:next_state, :idle, clear_acquire(data)}
  end

  def acquiring({:call, from}, {:toggle, _mode}, _data) do
    {:keep_state_and_data, [{:reply, from, "ok"}]}
  end

  def acquiring({:call, from}, :cancel, data) do
    abort_acquire(data)
    overlay(data, "cancelled", "")
    {:next_state, :idle, clear_acquire(data), [{:reply, from, "ok"}]}
  end

  def acquiring({:call, from}, :status, _data) do
    {:keep_state_and_data, [{:reply, from, "recording"}]}
  end

  def acquiring({:call, from}, {:retype, text}, data), do: handle_retype(from, text, data)
  def acquiring(:info, _message, _data), do: :keep_state_and_data

  # --- :recording ------------------------------------------------------------

  @doc false
  def recording({:call, from}, {:toggle, _mode}, data), do: finish_recording(from, data)

  def recording(:internal, :stop_phrase, data), do: finish_recording(nil, data)

  def recording({:call, from}, :cancel, data) do
    cancel_recording(data)
    overlay(data, "cancelled", "")
    {:next_state, :idle, clear_recording(data), cancel_timer_actions() ++ [{:reply, from, "ok"}]}
  end

  def recording({:call, from}, :status, _data) do
    {:keep_state_and_data, [{:reply, from, "recording"}]}
  end

  def recording({:call, from}, {:retype, text}, data), do: handle_retype(from, text, data)

  def recording({:timeout, :level}, :level_tick, data) do
    push_level(data)
    {:keep_state_and_data, [schedule_level(data)]}
  end

  def recording({:timeout, :watcher}, :watcher_tick, data) do
    {:keep_state, maybe_spawn_watcher(data), [schedule_watcher(data)]}
  end

  def recording(:info, {ref, watcher_result}, %{watcher_task: %{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    handle_watcher_result(watcher_result, %{data | watcher_task: nil})
  end

  def recording(:info, {:DOWN, ref, :process, _pid, _reason}, %{watcher_task: %{ref: ref}} = data) do
    {:keep_state, %{data | watcher_task: nil}}
  end

  def recording(:info, {:DOWN, ref, :process, _pid, reason}, %{recorder_ref: ref} = data) do
    Logger.warning("recorder went down mid-recording: #{inspect(reason)}")
    cancel_timers_and_watcher(data)
    overlay(data, "error", "Recorder stopped")
    {:next_state, :idle, clear_recording(data), cancel_timer_actions()}
  end

  def recording(:info, _message, _data), do: :keep_state_and_data

  # --- :transcribing ---------------------------------------------------------

  @doc false
  # A toggle during transcription starts a fresh recording (the running pipeline
  # keeps going and pastes when done) — matching the Python daemon.
  def transcribing({:call, from}, {:toggle, mode}, data) do
    overlay(data, "recording", mode)
    started = start_acquire(data, mode)
    {:next_state, :acquiring, started, [{:reply, from, "ok"}]}
  end

  def transcribing({:call, from}, :cancel, _data) do
    {:keep_state_and_data, [{:reply, from, "ok"}]}
  end

  def transcribing({:call, from}, :status, _data) do
    {:keep_state_and_data, [{:reply, from, "idle"}]}
  end

  def transcribing({:call, from}, {:retype, text}, data), do: handle_retype(from, text, data)

  def transcribing(:info, {ref, :pipeline_done}, %{pipeline_ref: ref} = data) do
    Process.demonitor(ref, [:flush])
    overlay(data, "idle", "")
    {:next_state, :idle, clear_pipeline(data)}
  end

  def transcribing(:info, {:DOWN, ref, :process, _pid, reason}, %{pipeline_ref: ref} = data) do
    overlay(data, "error", inspect(reason))
    {:next_state, :idle, clear_pipeline(data)}
  end

  def transcribing(:info, _message, _data), do: :keep_state_and_data

  # --- acquire ---------------------------------------------------------------

  @spec start_acquire(data(), String.t()) :: data()
  defp start_acquire(data, mode) do
    task = monitored_task(fn -> data.recorder_mod.start(data.recorder) end)
    %{data | mode: mode, acquire_task: task}
  end

  @spec abort_acquire(data()) :: :ok
  defp abort_acquire(data) do
    kill_task(data.acquire_task)
    data.recorder_mod.cancel(data.recorder)
    :ok
  end

  @spec clear_acquire(data()) :: data()
  defp clear_acquire(data), do: %{data | acquire_task: nil, mode: nil}

  # --- recording start -------------------------------------------------------

  @spec start_recording(data()) :: {data(), [:gen_statem.action()]}
  defp start_recording(data) do
    ref = Process.monitor(data.recorder)
    monitored = %{data | acquire_task: nil, recorder_ref: ref}
    {monitored, [schedule_level(monitored), schedule_watcher(monitored)]}
  end

  # --- finish recording → pipeline -------------------------------------------

  @spec finish_recording(:gen_statem.from() | nil, data()) ::
          :gen_statem.event_handler_result(atom())
  defp finish_recording(from, data) do
    cancel_timers_and_watcher(data)
    {:ok, pcm} = data.recorder_mod.stop(data.recorder)
    transition_for_audio(from, pcm, data)
  end

  @spec transition_for_audio(:gen_statem.from() | nil, binary(), data()) ::
          :gen_statem.event_handler_result(atom())
  defp transition_for_audio(from, pcm, data) when byte_size(pcm) < @min_audio_bytes do
    overlay(data, "error", "Recording too short")
    {:next_state, :idle, clear_recording(data), cancel_timer_actions() ++ reply_if(from)}
  end

  defp transition_for_audio(from, pcm, data) do
    overlay(data, "transcribing", "")
    task = spawn_pipeline(data, pcm)

    {:next_state, :transcribing, clear_recording_keep_pipeline(data, task),
     cancel_timer_actions() ++ reply_if(from)}
  end

  @spec reply_if(:gen_statem.from() | nil) :: [{:reply, :gen_statem.from(), String.t()}]
  defp reply_if(nil), do: []
  defp reply_if(from), do: [{:reply, from, "ok"}]

  # --- pipeline Task ---------------------------------------------------------

  @spec spawn_pipeline(data(), binary()) :: Task.t()
  defp spawn_pipeline(data, pcm) do
    mode = data.mode
    Task.async(fn -> transcribe_and_deliver(data, mode, pcm) end)
  end

  @spec transcribe_and_deliver(data(), String.t(), binary()) :: :pipeline_done
  defp transcribe_and_deliver(data, mode, pcm) do
    {:ok, raw} = transcriber().transcribe(pcm_to_tensor(pcm), serving: :final)
    Logger.debug("whisper raw output: #{inspect(raw)}")
    deliver_transcription(data, mode, PostProcess.run(raw))
  end

  # Build a sanitized Nx tensor from raw f32 PCM bytes. USB mic hardware can
  # produce NaN/Inf samples in the first few frames while the clock stabilizes;
  # feeding those into XLA crashes the Nx.Serving process. Replace with 0.0.
  @spec pcm_to_tensor(binary()) :: Nx.Tensor.t()
  defp pcm_to_tensor(pcm) do
    sanitized =
      for <<s::float-32-native <- pcm>>, into: <<>> do
        if finite?(s), do: <<s::float-32-native>>, else: <<0.0::float-32-native>>
      end

    Nx.from_binary(sanitized, :f32)
  end

  # IEEE-754: NaN != itself; Inf exceeds max finite float.
  defp finite?(s), do: s == s and abs(s) <= 3.4028235e38

  @spec deliver_transcription(data(), String.t(), String.t()) :: :pipeline_done
  defp deliver_transcription(data, mode, processed) do
    if PostProcess.meaningful?(processed),
      do: deliver_meaningful(data, mode, processed),
      else: nothing_heard(data)
  end

  @spec nothing_heard(data()) :: :pipeline_done
  defp nothing_heard(data) do
    Logger.warning("nothing heard: audio was silent or whisper output was empty")
    data.overlay_show.("error", "Nothing heard")
    :pipeline_done
  end

  @spec deliver_meaningful(data(), String.t(), String.t()) :: :pipeline_done
  defp deliver_meaningful(data, mode, processed) do
    final_text = maybe_ai_cleanup(data, mode, processed)
    data.history_append.(mode, final_text)
    data.typist_paste.(final_text)
    :pipeline_done
  end

  @spec maybe_ai_cleanup(data(), String.t(), String.t()) :: String.t()
  defp maybe_ai_cleanup(data, "ai", text), do: data.ai_cleanup.(text, data.config_load.())
  defp maybe_ai_cleanup(_data, _mode, text), do: text

  # --- retype ----------------------------------------------------------------

  @spec handle_retype(:gen_statem.from(), String.t(), data()) ::
          :gen_statem.event_handler_result(atom())
  defp handle_retype(from, text, data) do
    paste = data.typist_paste
    Task.start(fn -> paste.(text) end)
    {:keep_state_and_data, [{:reply, from, "ok"}]}
  end

  # --- watcher ---------------------------------------------------------------

  # Non-overlapping: skip the tick if a watcher Task is already in flight.
  @spec maybe_spawn_watcher(data()) :: data()
  defp maybe_spawn_watcher(%{watcher_task: %{}} = data), do: data

  defp maybe_spawn_watcher(data) do
    tail = data.recorder_mod.tail(data.recorder, @watcher_window_seconds)
    spawn_watcher_if_enough(data, tail)
  end

  @spec spawn_watcher_if_enough(data(), binary()) :: data()
  defp spawn_watcher_if_enough(data, tail) when byte_size(tail) < @watcher_min_bytes, do: data

  defp spawn_watcher_if_enough(data, tail) do
    task =
      monitored_task(fn ->
        transcriber().transcribe(Nx.from_binary(tail, :f32), serving: :watcher)
      end)

    %{data | watcher_task: task}
  end

  @spec handle_watcher_result({:ok, String.t()} | term(), data()) ::
          :gen_statem.event_handler_result(atom())
  defp handle_watcher_result({:ok, text}, data) do
    stop_or_keep(PostProcess.stop_phrase?(text), data)
  end

  defp handle_watcher_result(_other, data), do: {:keep_state, data}

  @spec stop_or_keep(boolean(), data()) :: :gen_statem.event_handler_result(atom())
  defp stop_or_keep(true, data), do: {:keep_state, data, [{:next_event, :internal, :stop_phrase}]}
  defp stop_or_keep(false, data), do: {:keep_state, data}

  # --- timers ----------------------------------------------------------------

  @spec schedule_level(data()) :: :gen_statem.action()
  defp schedule_level(data), do: {{:timeout, :level}, data.level_interval_ms, :level_tick}

  @spec schedule_watcher(data()) :: :gen_statem.action()
  defp schedule_watcher(data), do: {{:timeout, :watcher}, data.watcher_interval_ms, :watcher_tick}

  # Cancel both named recording timeouts (gen_statem cancels a named timeout when
  # its time is set to `:infinity`), so no stale tick fires after leaving
  # `:recording`.
  @spec cancel_timer_actions() :: [:gen_statem.action()]
  defp cancel_timer_actions do
    [{{:timeout, :level}, :infinity, nil}, {{:timeout, :watcher}, :infinity, nil}]
  end

  @spec push_level(data()) :: :ok
  defp push_level(data) do
    scaled = min(1.0, data.recorder_mod.level(data.recorder) * 20)
    data.overlay_level.(scaled)
    :ok
  end

  # --- teardown --------------------------------------------------------------

  @spec cancel_recording(data()) :: :ok
  defp cancel_recording(data) do
    cancel_timers_and_watcher(data)
    data.recorder_mod.cancel(data.recorder)
    :ok
  end

  @spec cancel_timers_and_watcher(data()) :: :ok
  defp cancel_timers_and_watcher(data) do
    demonitor_recorder(data)
    kill_task(data.watcher_task)
    :ok
  end

  @spec clear_recording(data()) :: data()
  defp clear_recording(data) do
    %{data | recorder_ref: nil, watcher_task: nil, mode: nil}
  end

  @spec clear_recording_keep_pipeline(data(), Task.t()) :: data()
  defp clear_recording_keep_pipeline(data, task) do
    data
    |> Map.put(:recorder_ref, nil)
    |> Map.put(:watcher_task, nil)
    |> Map.put(:pipeline_ref, task.ref)
  end

  @spec clear_pipeline(data()) :: data()
  defp clear_pipeline(data), do: Map.put(data, :pipeline_ref, nil) |> Map.put(:mode, nil)

  @spec demonitor_recorder(data()) :: :ok
  defp demonitor_recorder(%{recorder_ref: nil}), do: :ok

  defp demonitor_recorder(%{recorder_ref: ref}) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  # --- task helpers ----------------------------------------------------------

  @spec monitored_task((-> term())) :: Task.t()
  defp monitored_task(fun), do: Task.async(fun)

  @spec kill_task(Task.t() | nil) :: :ok
  defp kill_task(nil), do: :ok

  defp kill_task(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  # --- collaborators ---------------------------------------------------------

  @spec overlay(data(), String.t(), String.t()) :: :ok
  defp overlay(data, state, text) do
    data.overlay_show.(state, text)
    :ok
  end

  @spec transcriber() :: module()
  defp transcriber, do: Application.fetch_env!(:voxd, :transcriber)
end
