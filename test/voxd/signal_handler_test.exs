defmodule Voxd.SignalHandlerTest do
  use ExUnit.Case, async: false

  alias Voxd.SignalHandler

  @moduledoc """
  Exercises the cleanup contract directly with injected effect functions and
  runtime-file paths, so no real signal is raised, no mic/overlay is touched, and
  the real `/tmp` files are never removed. The signal plumbing itself
  (`:os.set_signal` + `:gen_event.swap_sup_handler`) is verified by the boot
  check in Task 13, not here.
  """

  setup do
    tmp = System.tmp_dir!()
    suffix = System.unique_integer([:positive])

    files = [
      Path.join(tmp, "voxd-sig-#{suffix}.sock"),
      Path.join(tmp, "voxd-sig-#{suffix}.pid"),
      Path.join(tmp, "voxd-sig-#{suffix}-ready")
    ]

    Enum.each(files, &File.touch/1)
    on_exit(fn -> Enum.each(files, &File.rm/1) end)
    {:ok, files: files}
  end

  test "cleanup releases the session, idles the overlay, and removes runtime files", %{
    files: files
  } do
    test_pid = self()

    assert :ok =
             SignalHandler.cleanup(
               session_cancel: fn -> send(test_pid, :session_cancelled) end,
               overlay_idle: fn -> send(test_pid, :overlay_idled) end,
               runtime_files: files
             )

    assert_received :session_cancelled
    assert_received :overlay_idled
    refute Enum.any?(files, &File.exists?/1)
  end

  test "cleanup tolerates already-missing runtime files" do
    missing = [Path.join(System.tmp_dir!(), "voxd-absent-#{System.unique_integer([:positive])}")]

    assert :ok =
             SignalHandler.cleanup(
               session_cancel: fn -> :ok end,
               overlay_idle: fn -> :ok end,
               runtime_files: missing
             )
  end
end
