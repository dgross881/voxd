defmodule Voxd.RecorderTest do
  use ExUnit.Case, async: true

  alias Voxd.Recorder

  @sample_count 16_000

  setup context do
    tmp_dir = Path.join(System.tmp_dir!(), "voxd-recorder-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    constant = constant_f32(0.5, @sample_count)
    constant_path = Path.join(tmp_dir, "constant.raw")
    File.write!(constant_path, constant)

    zeros = constant_f32(0.0, @sample_count)
    zeros_path = Path.join(tmp_dir, "zeros.raw")
    File.write!(zeros_path, zeros)

    name = :"recorder_#{context.test |> to_string() |> String.replace(~r/\W/, "_")}"

    %{
      tmp_dir: tmp_dir,
      constant: constant,
      constant_path: constant_path,
      zeros_path: zeros_path,
      name: name
    }
  end

  # Build a raw little/native-endian f32 PCM buffer of `count` identical samples.
  defp constant_f32(value, count) do
    for _ <- 1..count, into: <<>>, do: <<value::float-32-native>>
  end

  defp start_recorder(ctx, command, extra_opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: ctx.name,
          command: command,
          warmup_deadline_ms: 1_500,
          spawn_retry_delay_ms: 10
        ],
        extra_opts
      )

    pid = start_supervised!({Recorder, opts})
    {pid, ctx.name}
  end

  describe "happy path — start/stop returns the full non-zero capture" do
    test "stop returns every byte of a non-silent fixture", ctx do
      {_pid, name} = start_recorder(ctx, ["cat", ctx.constant_path])

      assert :ok = Recorder.start(name)

      # Let cat stream the whole fixture and hit EOF, then release.
      assert {:ok, audio} = stop_when_eof(name)
      assert audio == ctx.constant
      refute Recorder.recording?(name)
    end
  end

  describe "warm-up discards leading all-zero chunks" do
    test "a silent chunk before the first live chunk is dropped from the capture", ctx do
      # The sleep forces the zeros to arrive as their own read (a silent chunk
      # that must be discarded), then the constant fixture arrives as the first
      # live chunk and is kept in full. Without the sleep `cat` would glue both
      # into one chunk, which is kept whole — chunk granularity is the contract.
      command =
        ["sh", "-c", "head -c 8000 #{ctx.zeros_path}; sleep 0.2; cat #{ctx.constant_path}"]

      {_pid, name} = start_recorder(ctx, command)

      assert :ok = Recorder.start(name)
      assert {:ok, audio} = stop_when_eof(name)

      # The all-zero warm-up chunk is gone; exactly the constant fixture remains.
      assert audio == ctx.constant
    end
  end

  describe "process crash mid-recording" do
    test "chunks captured before a non-zero exit are returned by stop", ctx do
      command = ["sh", "-c", "cat #{ctx.constant_path}; exit 1"]
      {_pid, name} = start_recorder(ctx, command)

      assert :ok = Recorder.start(name)
      assert {:ok, audio} = stop_when_eof(name)
      assert audio == ctx.constant
    end
  end

  describe "slow warm-up" do
    test "a fixture that starts after a delay still acquires within the deadline", ctx do
      command = ["sh", "-c", "sleep 0.3; cat #{ctx.constant_path}"]
      {_pid, name} = start_recorder(ctx, command)

      assert :ok = Recorder.start(name)
      assert {:ok, audio} = stop_when_eof(name)
      assert audio == ctx.constant
    end
  end

  describe "silent input — respawn then best-effort" do
    test "all-zero input past the deadline respawns once then returns :ok", ctx do
      command = ["sh", "-c", "head -c 64000 #{ctx.zeros_path}; sleep 5"]

      {_pid, name} =
        start_recorder(ctx, command, warmup_deadline_ms: 120, spawn_retry_delay_ms: 5)

      assert :ok = Recorder.start(name)
      assert Recorder.recording?(name)
      assert :ok = Recorder.cancel(name)
    end
  end

  describe "spawn failure" do
    test "a missing binary yields :no_input_device after retrying", ctx do
      {_pid, name} =
        start_recorder(ctx, ["definitely-missing-binary-xyz-voxd"], spawn_retry_delay_ms: 5)

      assert {:error, :no_input_device} = Recorder.start(name)
      refute Recorder.recording?(name)
    end
  end

  describe "level/0" do
    test "RMS of a constant-0.5 fixture is approximately 0.5", ctx do
      {_pid, name} = start_recorder(ctx, ["cat", ctx.constant_path])

      assert :ok = Recorder.start(name)
      wait_until(fn -> Recorder.level(name) > 0.0 end)
      assert_in_delta Recorder.level(name), 0.5, 0.01
      assert :ok = Recorder.cancel(name)
    end
  end

  describe "stop without start" do
    test "returns :not_recording", ctx do
      {_pid, name} = start_recorder(ctx, ["cat", ctx.constant_path])
      assert {:error, :not_recording} = Recorder.stop(name)
    end

    test "cancel without start is a no-op :ok", ctx do
      {_pid, name} = start_recorder(ctx, ["cat", ctx.constant_path])
      assert :ok = Recorder.cancel(name)
    end
  end

  # Poll until the reader has signalled EOF, then stop — pins that stop returns
  # exactly what was captured, not a race with in-flight chunks.
  defp stop_when_eof(name) do
    wait_until(fn -> not Recorder.recording?(name) end)
    Recorder.stop(name)
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
