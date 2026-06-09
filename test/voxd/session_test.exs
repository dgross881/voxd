defmodule Voxd.SessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Voxd.Session

  # 0.3 s of audio = 4800 samples = 19_200 bytes. Just over the minimum.
  @ok_pcm :binary.copy(<<0.1::float-32-native>>, 5_000)
  # Under the 19_200-byte minimum (too short).
  @short_pcm :binary.copy(<<0.1::float-32-native>>, 100)
  # 1 s of audio for the watcher tail (>= 0.5 s).
  @one_second_pcm :binary.copy(<<0.1::float-32-native>>, 16_000)
  # 0.25 s — below the 0.5 s watcher floor.
  @quarter_second_pcm :binary.copy(<<0.1::float-32-native>>, 4_000)

  # The Transcriber.Mock is called from spawned Tasks (pipeline + watcher), so a
  # private-mode expectation set on the test process would not be visible there.
  # Global mode makes the mock answer regardless of caller; the suite is
  # async: false so global mode is safe.
  setup :set_mox_global
  setup :verify_on_exit!

  # --- a stub Recorder that speaks the real Voxd.Recorder call protocol -------
  defmodule StubRecorder do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(:start, _from, state) do
      {:reply, Map.get(state, :acquire_result, :ok), state}
    end

    def handle_call(:stop, _from, state) do
      {:reply, {:ok, Map.get(state, :pcm, <<>>)}, state}
    end

    def handle_call(:cancel, _from, state), do: {:reply, :ok, state}
    def handle_call(:level, _from, state), do: {:reply, Map.get(state, :level, 0.0), state}

    def handle_call({:tail, _seconds}, _from, state) do
      {:reply, Map.get(state, :tail, <<>>), state}
    end
  end

  defp start_stub_recorder(opts \\ []) do
    start_supervised!({StubRecorder, opts}, id: {StubRecorder, make_ref()})
  end

  # Effector functions that forward every call to the test process as a message,
  # so a test can assert the exact effect sequence.
  defp recording_effectors(test_pid) do
    [
      overlay_show: fn state, text -> send(test_pid, {:overlay, state, text}) end,
      overlay_level: fn value -> send(test_pid, {:level, value}) end,
      typist_paste: fn text -> send(test_pid, {:paste, text}) end,
      ai_cleanup: fn text, _config ->
        send(test_pid, {:ai, text})
        "AI(" <> text <> ")"
      end,
      history_append: fn mode, text -> send(test_pid, {:history, mode, text}) end,
      config_load: fn -> %{"ai" => %{}} end
    ]
  end

  defp start_session(recorder, extra_opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          recorder: recorder,
          recorder_mod: __MODULE__.StubRecorderClient,
          level_interval_ms: 10,
          watcher_interval_ms: 10
        ] ++ recording_effectors(self()),
        extra_opts
      )

    start_supervised!({Session, opts}, id: {Session, make_ref()})
  end

  # The Session calls the recorder through a module whose functions take the
  # server first; StubRecorder speaks the protocol directly, so a thin client
  # module maps the public API onto plain GenServer calls.
  defmodule StubRecorderClient do
    def start(server), do: GenServer.call(server, :start)
    def stop(server), do: GenServer.call(server, :stop)
    def cancel(server), do: GenServer.call(server, :cancel)
    def level(server), do: GenServer.call(server, :level)
    def tail(server, seconds), do: GenServer.call(server, {:tail, seconds})
  end

  defp final_transcribe(text) do
    expect(Voxd.Transcriber.Mock, :transcribe, fn _tensor, opts ->
      assert opts[:serving] == :final
      {:ok, text}
    end)
  end

  describe "invalid mode" do
    test "toggle with an unknown mode returns \"unknown\" and stays idle" do
      session = start_session(start_stub_recorder())

      assert Session.toggle(session, "bogus") == "unknown"
      assert Session.status(session) == "idle"
    end
  end

  describe "toggle / toggle happy path (dictation)" do
    test "audio flows through the pipeline; post-processed text is pasted and stored" do
      # PostProcess.run trims/appends a space; "hello world" -> "hello world ".
      final_transcribe("hello world")
      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      assert_receive {:overlay, "recording", "dictation"}
      wait_for_state(session, :recording)

      assert Session.toggle(session, "dictation") == "ok"
      assert_receive {:overlay, "transcribing", _}

      assert_receive {:history, "dictation", "hello world "}
      assert_receive {:paste, "hello world "}
      assert_receive {:overlay, "idle", _}
      refute_received {:ai, _}

      wait_for_status(session, "idle")
    end
  end

  describe "AI mode routing" do
    test "ai mode runs text through AI.cleanup before history and paste" do
      final_transcribe("draft text")
      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "ai") == "ok"
      assert_receive {:overlay, "recording", "ai"}
      wait_for_state(session, :recording)
      assert Session.toggle(session, "ai") == "ok"

      assert_receive {:ai, "draft text "}
      assert_receive {:history, "ai", "AI(draft text )"}
      assert_receive {:paste, "AI(draft text )"}
    end
  end

  describe "empty post-processed transcription" do
    test "shows \"Nothing heard\" and does not paste or store history" do
      final_transcribe("")
      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Session.toggle(session, "dictation") == "ok"

      assert_receive {:overlay, "error", "Nothing heard"}
      refute_received {:paste, _}
      refute_received {:history, _, _}
      wait_for_status(session, "idle")
    end
  end

  describe "silent audio" do
    # No silence pre-filter (matching Python daemon which has none). All-zero
    # audio reaches Whisper, which returns empty string; meaningful? rejects it.
    test "all-zero audio shows \"Nothing heard\" via meaningful? guard" do
      final_transcribe("")
      silent_pcm = :binary.copy(<<0.0::float-32-native>>, 8_000)
      recorder = start_stub_recorder(pcm: silent_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Session.toggle(session, "dictation") == "ok"

      assert_receive {:overlay, "error", "Nothing heard"}
      refute_receive {:paste, _}, 50
      refute_receive {:history, _, _}, 50
      wait_for_status(session, "idle")
    end
  end

  describe "hallucinated punctuation-only transcription" do
    test "text with no letters or digits shows \"Nothing heard\" and is not pasted" do
      final_transcribe(String.duplicate("!", 80))
      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Session.toggle(session, "dictation") == "ok"

      assert_receive {:overlay, "error", "Nothing heard"}
      refute_receive {:paste, _}, 50
      refute_receive {:history, _, _}, 50
      wait_for_status(session, "idle")
    end
  end

  describe "too-short audio" do
    test "audio under 0.3 s shows an error and returns to idle without transcribing" do
      stub(Voxd.Transcriber.Mock, :transcribe, fn _tensor, _opts ->
        flunk("transcribe must not be called for too-short audio")
      end)

      recorder = start_stub_recorder(pcm: @short_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Session.toggle(session, "dictation") == "ok"

      assert_receive {:overlay, "error", "Recording too short"}
      refute_received {:paste, _}
      wait_for_status(session, "idle")
    end
  end

  describe "acquiring state" do
    test "double-toggle while acquiring is ignored (no double start)" do
      # A recorder whose :start blocks lets us observe the :acquiring window.
      {:ok, gate} = Agent.start_link(fn -> nil end)
      recorder = start_blocking_recorder(gate)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      assert_receive {:overlay, "recording", "dictation"}
      # Status is "recording" for :acquiring too.
      assert Session.status(session) == "recording"

      # Second toggle during :acquiring is acknowledged but changes nothing.
      assert Session.toggle(session, "dictation") == "ok"

      release_blocking_recorder(gate)
      wait_for_state(session, :recording)
      # Exactly one acquire happened.
      assert acquire_count(gate) == 1
    end

    test "acquire failure shows \"No input device\" and returns to idle" do
      recorder = start_stub_recorder(acquire_result: {:error, :no_input_device})
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      assert_receive {:overlay, "error", "No input device"}
      wait_for_status(session, "idle")
    end

    test "cancel during acquiring returns to idle with a cancelled overlay" do
      {:ok, gate} = Agent.start_link(fn -> nil end)
      recorder = start_blocking_recorder(gate)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      assert Session.status(session) == "recording"

      assert Session.cancel(session) == "ok"
      release_blocking_recorder(gate)

      assert_receive {:overlay, "cancelled", _}
      wait_for_status(session, "idle")
    end
  end

  describe "cancel" do
    test "cancel in idle is a no-op \"ok\"" do
      session = start_session(start_stub_recorder())
      assert Session.cancel(session) == "ok"
      assert Session.status(session) == "idle"
    end

    test "cancel while recording stops capture and returns to idle" do
      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      assert Session.cancel(session) == "ok"
      assert_receive {:overlay, "cancelled", _}
      wait_for_status(session, "idle")
    end

    test "cancel while transcribing is a no-op (transcription not cancellable)" do
      # Block the transcribe so we stay in :transcribing while we cancel.
      {:ok, gate} = Agent.start_link(fn -> nil end)

      expect(Voxd.Transcriber.Mock, :transcribe, fn _tensor, _opts ->
        wait_for_gate(gate)
        {:ok, "later"}
      end)

      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Session.toggle(session, "dictation") == "ok"
      assert_receive {:overlay, "transcribing", _}

      # During :transcribing, cancel must not abort the pipeline.
      assert Session.cancel(session) == "ok"

      release_gate(gate)
      assert_receive {:paste, "later "}
    end
  end

  describe "watcher stop phrase" do
    test "a stop-phrase watcher result ends the recording exactly like toggle" do
      # Watcher transcribe returns a stop phrase → recording ends; the final pass
      # then transcribes the captured audio and pastes it.
      Voxd.Transcriber.Mock
      |> expect(:transcribe, fn _tensor, opts ->
        assert opts[:serving] == :watcher
        {:ok, "end recording"}
      end)
      |> expect(:transcribe, fn _tensor, opts ->
        assert opts[:serving] == :final
        {:ok, "captured words"}
      end)

      recorder = start_stub_recorder(pcm: @ok_pcm, tail: @one_second_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      # No manual toggle — the watcher ends it.
      assert_receive {:overlay, "transcribing", _}, 1_000
      assert_receive {:paste, "captured words "}, 1_000
      wait_for_status(session, "idle")
    end

    test "a non-stop watcher result keeps recording" do
      stub(Voxd.Transcriber.Mock, :transcribe, fn _tensor, opts ->
        case opts[:serving] do
          :watcher -> {:ok, "just chatting along"}
          :final -> {:ok, "final text"}
        end
      end)

      recorder = start_stub_recorder(pcm: @ok_pcm, tail: @one_second_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      # Give several watcher ticks a chance to fire; recording must persist.
      Process.sleep(60)
      assert Session.status(session) == "recording"
    end

    test "watcher tick is skipped when the tail is under 0.5 s (no transcribe)" do
      parent = self()

      stub(Voxd.Transcriber.Mock, :transcribe, fn _tensor, opts ->
        send(parent, {:transcribe_called, opts[:serving]})
        {:ok, ""}
      end)

      recorder = start_stub_recorder(pcm: @ok_pcm, tail: @quarter_second_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      Process.sleep(60)
      refute_received {:transcribe_called, :watcher}
      assert Session.cancel(session) == "ok"
    end

    test "overlapping watcher ticks are skipped (one watcher in flight at a time)" do
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Voxd.Transcriber.Mock, :transcribe, fn _tensor, opts ->
        case opts[:serving] do
          :watcher ->
            Agent.update(counter, &(&1 + 1))
            send(parent, :watcher_started)
            # Hold longer than several tick intervals: any second concurrent
            # watcher would bump the counter past 1 here.
            Process.sleep(80)
            {:ok, "still talking"}

          :final ->
            {:ok, "done"}
        end
      end)

      recorder = start_stub_recorder(pcm: @ok_pcm, tail: @one_second_pcm)
      # 10 ms watcher interval but an 80 ms watcher run → must not overlap.
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      assert_receive :watcher_started, 500
      Process.sleep(50)
      assert Agent.get(counter, & &1) == 1

      assert Session.cancel(session) == "ok"
    end
  end

  describe "level metering" do
    test "level ticks push scaled rms to the overlay while recording" do
      recorder = start_stub_recorder(pcm: @ok_pcm, level: 0.02)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      # min(1.0, 0.02 * 20) = 0.4.
      assert_receive {:level, value}, 500
      assert_in_delta value, 0.4, 0.0001

      assert Session.cancel(session) == "ok"
    end

    test "level is clamped to 1.0" do
      recorder = start_stub_recorder(pcm: @ok_pcm, level: 5.0)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      assert_receive {:level, 1.0}, 500
      assert Session.cancel(session) == "ok"
    end
  end

  describe "recorder DOWN" do
    @tag capture_log: true
    test "recorder crash mid-recording shows an error and returns to idle" do
      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)

      Process.exit(recorder, :kill)

      assert_receive {:overlay, "error", _}
      wait_for_status(session, "idle")
    end
  end

  describe "default effector wiring" do
    # Regression: the daemon's first live toggle crashed with
    # GenServer.whereis("recording") — default_overlay_show called
    # Overlay.show(state, text), which bound `state` to show/3's `server`
    # default argument. Every other test injects stub effectors, so only a
    # Session started WITHOUT overlay overrides exercises the real wiring.
    @tag :tmp_dir
    test "toggle works with the real Overlay defaults", %{tmp_dir: tmp_dir} do
      pipe = Path.join(tmp_dir, "overlay.pipe")

      start_supervised!(
        {Voxd.Overlay, name: Voxd.Overlay, pipe_path: pipe, supervise_process: false}
      )

      recorder = start_stub_recorder(pcm: @ok_pcm)

      session_opts =
        [name: nil, recorder: recorder, recorder_mod: __MODULE__.StubRecorderClient] ++
          Keyword.drop(recording_effectors(self()), [:overlay_show, :overlay_level])

      session = start_supervised!({Session, session_opts}, id: {Session, make_ref()})

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Process.alive?(session)
    end
  end

  describe "transcription task crash" do
    # The mock deliberately raises; capture the expected crash report so the
    # suite output stays clean.
    @tag capture_log: true
    test "a crashing pipeline task shows an error and returns to idle" do
      expect(Voxd.Transcriber.Mock, :transcribe, fn _tensor, _opts ->
        raise "gpu exploded"
      end)

      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Session.toggle(session, "dictation") == "ok"

      assert_receive {:overlay, "error", _reason}
      wait_for_status(session, "idle")
    end
  end

  describe "toggle while transcribing starts a new recording" do
    test "toggle during transcribing behaves like toggle from idle" do
      {:ok, gate} = Agent.start_link(fn -> nil end)

      Voxd.Transcriber.Mock
      |> expect(:transcribe, fn _tensor, _opts ->
        wait_for_gate(gate)
        {:ok, "first"}
      end)

      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      assert Session.toggle(session, "dictation") == "ok"
      wait_for_state(session, :recording)
      assert Session.toggle(session, "dictation") == "ok"
      assert_receive {:overlay, "transcribing", _}

      # Toggle while still transcribing → starts recording again.
      assert Session.toggle(session, "dictation") == "ok"
      assert_receive {:overlay, "recording", "dictation"}
      wait_for_state(session, :recording)

      # The first pipeline task is still alive; release it and assert it pastes.
      release_gate(gate)
      assert_receive {:paste, "first "}

      assert Session.cancel(session) == "ok"
    end
  end

  describe "retype" do
    test "retype pastes raw text without post-process, history, or AI" do
      session = start_session(start_stub_recorder())

      assert Session.retype(session, "verbatim text") == "ok"
      assert_receive {:paste, "verbatim text"}
      refute_received {:history, _, _}
      refute_received {:ai, _}
    end
  end

  describe "state-change logging" do
    test "each state transition is logged at debug level" do
      recorder = start_stub_recorder(pcm: @ok_pcm)
      session = start_session(recorder)

      log =
        capture_log([level: :debug], fn ->
          assert Session.toggle(session, "dictation") == "ok"
          wait_for_state(session, :recording)
        end)

      assert log =~ "session: idle -> acquiring"
      assert log =~ "session: acquiring -> recording"
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp wait_for_status(session, expected, attempts \\ 200) do
    cond do
      Session.status(session) == expected -> :ok
      attempts == 0 -> flunk("status never became #{expected}")
      true -> Process.sleep(5) && wait_for_status(session, expected, attempts - 1)
    end
  end

  # Wait for the real gen_statem state atom (`status/1` conflates :acquiring and
  # :recording into "recording", which is not precise enough for the toggle path).
  defp wait_for_state(session, expected, attempts \\ 200) do
    cond do
      statem_state(session) == expected -> :ok
      attempts == 0 -> flunk("state never became #{inspect(expected)}")
      true -> Process.sleep(5) && wait_for_state(session, expected, attempts - 1)
    end
  end

  defp statem_state(session) do
    {state, _data} = :sys.get_state(session)
    state
  end

  # A recorder GenServer whose :start defers its reply until released, so the
  # test can observe the :acquiring window while the recorder still serves other
  # calls (:cancel, :stop) concurrently — exactly like the real Recorder.
  defmodule BlockingRecorder do
    use GenServer

    @impl true
    def init(gate), do: {:ok, %{gate: gate, pending_start: nil, released: false}}

    @impl true
    def handle_call(:start, from, state) do
      Agent.update(state.gate, fn s -> %{s | acquires: s.acquires + 1} end)
      maybe_reply_start(%{state | pending_start: from})
    end

    def handle_call(:cancel, _from, state), do: {:reply, :ok, state}
    def handle_call(:stop, _from, state), do: {:reply, {:ok, <<>>}, state}
    def handle_call(:level, _from, state), do: {:reply, 0.0, state}
    def handle_call({:tail, _}, _from, state), do: {:reply, <<>>, state}

    @impl true
    def handle_info(:release, state) do
      maybe_reply_start(%{state | released: true})
    end

    defp maybe_reply_start(%{released: true, pending_start: from} = state) when from != nil do
      GenServer.reply(from, :ok)
      {:noreply, %{state | pending_start: nil}}
    end

    defp maybe_reply_start(state), do: {:noreply, state}
  end

  defp start_blocking_recorder(gate) do
    Agent.update(gate, fn _ -> %{acquires: 0} end)
    {:ok, pid} = GenServer.start_link(BlockingRecorder, gate)
    Process.put(:blocking_recorder_pid, pid)
    pid
  end

  defp release_blocking_recorder(_gate) do
    send(Process.get(:blocking_recorder_pid), :release)
    :ok
  end

  defp acquire_count(gate), do: Agent.get(gate, & &1.acquires)

  defp wait_for_gate(gate) do
    case Agent.get(gate, & &1) do
      :go -> :ok
      _ -> Process.sleep(5) && wait_for_gate(gate)
    end
  end

  defp release_gate(gate), do: Agent.update(gate, fn _ -> :go end)
end
