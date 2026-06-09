defmodule Voxd.TypistTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Voxd.Typist

  doctest Voxd.Typist

  # The options System.cmd/3 actually accepts. The production bug "invalid
  # option :input" slipped through because the stub runner accepted anything;
  # validating here keeps the stub honest about the System.cmd/3 contract.
  @system_cmd_opts [:into, :lines, :cd, :env, :arg0, :stderr_to_stdout, :parallelism, :use_stdio]

  setup do
    test_pid = self()

    runner = fn cmd, args, opts ->
      for {key, _value} <- opts do
        assert key in @system_cmd_opts, "System.cmd/3 does not support option #{inspect(key)}"
      end

      send(test_pid, {:cmd, cmd, args, opts})
      {"", 0}
    end

    sleeper = fn ms -> send(test_pid, {:slept, ms}) end

    %{runner: runner, sleeper: sleeper}
  end

  describe "type/2 — wl-copy then ydotool sequence" do
    test "single line: wl-copy, sleep 500, one type, no ENTER", ctx do
      Typist.type("hello world", runner: ctx.runner, sleeper: ctx.sleeper)

      assert_received {:cmd, "wl-copy", ["--", "hello world"], []}

      assert_received {:slept, 500}

      assert_received {:cmd, "ydotool",
                       ["type", "--next-delay", "20", "--key-delay", "20", "--", "hello world"],
                       _}

      refute_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}
    end

    test "multi line: type/ENTER interleaved in exact order", ctx do
      Typist.type("one\ntwo\nthree", runner: ctx.runner, sleeper: ctx.sleeper)

      assert_received {:cmd, "wl-copy", ["--", "one\ntwo\nthree"], _}
      assert_received {:slept, 500}

      assert_received {:cmd, "ydotool",
                       ["type" | ["--next-delay", "20", "--key-delay", "20", "--", "one"]], _}

      assert_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}

      assert_received {:cmd, "ydotool",
                       ["type", "--next-delay", "20", "--key-delay", "20", "--", "two"], _}

      assert_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}

      assert_received {:cmd, "ydotool",
                       ["type", "--next-delay", "20", "--key-delay", "20", "--", "three"], _}

      refute_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}
    end

    test "trailing newline presses a final ENTER but skips the empty type", ctx do
      Typist.type("line\n", runner: ctx.runner, sleeper: ctx.sleeper)

      assert_received {:cmd, "ydotool",
                       ["type", "--next-delay", "20", "--key-delay", "20", "--", "line"], _}

      assert_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}
      refute_received {:cmd, "ydotool", ["type" | _], _}
    end

    test "empty interior line: ENTER still pressed, type skipped", ctx do
      Typist.type("a\n\nb", runner: ctx.runner, sleeper: ctx.sleeper)

      assert_received {:cmd, "ydotool",
                       ["type", "--next-delay", "20", "--key-delay", "20", "--", "a"], _}

      assert_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}
      # blank line: no type, just the separating ENTER
      assert_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}

      assert_received {:cmd, "ydotool",
                       ["type", "--next-delay", "20", "--key-delay", "20", "--", "b"], _}
    end
  end

  describe "ENTER fallback to KEY_RETURN" do
    test "nonzero KEY_ENTER triggers a KEY_RETURN retry", _ctx do
      test_pid = self()

      runner = fn
        "ydotool", ["key", "KEY_ENTER"], _opts ->
          send(test_pid, {:cmd, "ydotool", ["key", "KEY_ENTER"], []})
          {"no socket", 1}

        cmd, args, opts ->
          send(test_pid, {:cmd, cmd, args, opts})
          {"", 0}
      end

      Typist.type("a\nb", runner: runner, sleeper: fn _ -> :ok end)

      assert_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}
      assert_received {:cmd, "ydotool", ["key", "KEY_RETURN"], _}
    end

    test "zero KEY_ENTER does not trigger KEY_RETURN", ctx do
      Typist.type("a\nb", runner: ctx.runner, sleeper: ctx.sleeper)

      assert_received {:cmd, "ydotool", ["key", "KEY_ENTER"], _}
      refute_received {:cmd, "ydotool", ["key", "KEY_RETURN"], _}
    end
  end

  describe "YDOTOOL_SOCKET environment" do
    test "every ydotool call carries the socket env, wl-copy does not", ctx do
      Typist.type("a\nb", runner: ctx.runner, sleeper: ctx.sleeper)

      assert_received {:cmd, "wl-copy", _, wl_opts}
      refute Keyword.has_key?(wl_opts, :env)

      ydotool_envs =
        collect_cmds()
        |> Enum.filter(fn {cmd, _args, _opts} -> cmd == "ydotool" end)
        |> Enum.map(fn {_cmd, _args, opts} -> Keyword.get(opts, :env) end)

      assert ydotool_envs != []

      Enum.each(ydotool_envs, fn env ->
        assert {socket_var, socket_path} =
                 Enum.find(env, fn {k, _v} -> k == "YDOTOOL_SOCKET" end)

        assert socket_var == "YDOTOOL_SOCKET"
        assert socket_path =~ ~r{^/run/user/\d+/\.ydotool_socket$}
      end)
    end
  end

  describe "failure logging" do
    test "a non-zero ydotool exit is logged with its output" do
      failing = fn _cmd, _args, _opts -> {"no socket", 1} end

      log =
        capture_log([level: :warning], fn ->
          Typist.type("hello", runner: failing, sleeper: fn _ -> :ok end)
        end)

      assert log =~ "typist: ydotool type exited 1"
      assert log =~ "no socket"
    end
  end

  defp collect_cmds(acc \\ []) do
    receive do
      {:cmd, cmd, args, opts} -> collect_cmds([{cmd, args, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
