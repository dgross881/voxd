defmodule Voxd.ReadyTest do
  use ExUnit.Case, async: false

  alias Voxd.Ready

  @moduledoc """
  The readiness flag is `:persistent_term`-backed and starts `false`. Marking
  ready flips the flag and touches the ready file; the file path is injectable so
  the test never writes the real `/tmp/voxd-ready`.
  """

  setup do
    :persistent_term.erase(Ready.term_key())
    path = Path.join(System.tmp_dir!(), "voxd-ready-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "defaults to not ready" do
    refute Ready.ready?()
  end

  test "mark_ready/1 flips the flag and touches the ready file", %{path: path} do
    refute File.exists?(path)

    assert :ok = Ready.mark_ready(path)

    assert Ready.ready?()
    assert File.exists?(path)
  end
end
