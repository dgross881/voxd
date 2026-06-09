defmodule Voxd.HotkeyTest do
  use ExUnit.Case, async: true

  alias Voxd.Hotkey

  @keycode 464

  # Start a Hotkey with the device reader stubbed out (so no /dev/input access)
  # and the toggle effect redirected to the test process. Key events are
  # injected as plain messages — the same `{:key, code, value}` the real reader
  # sends — so the hold logic is exercised with no hardware.
  defp start_hotkey(test_pid, opts \\ []) do
    base = [
      name: nil,
      reader: fn _owner -> :ok end,
      keycode: @keycode,
      hold_ms: 40,
      toggle_fun: fn -> send(test_pid, :toggled) end
    ]

    start_supervised!({Hotkey, Keyword.merge(base, opts)}, id: {Hotkey, make_ref()})
  end

  defp press(hotkey), do: send(hotkey, {:key, @keycode, 1})
  defp release(hotkey), do: send(hotkey, {:key, @keycode, 0})

  describe "push-to-talk" do
    test "holding past the threshold starts recording (one toggle)" do
      hotkey = start_hotkey(self())

      press(hotkey)

      assert_receive :toggled, 200
      refute_receive :toggled, 80
    end

    test "releasing after the hold started fires a second toggle (stop)" do
      hotkey = start_hotkey(self())

      press(hotkey)
      assert_receive :toggled, 200

      release(hotkey)
      assert_receive :toggled, 200
    end

    test "releasing before the threshold fires nothing (a tap)" do
      hotkey = start_hotkey(self())

      press(hotkey)
      release(hotkey)

      refute_receive :toggled, 120
    end

    test "a second hold-and-release cycle toggles start then stop again" do
      hotkey = start_hotkey(self())

      press(hotkey)
      assert_receive :toggled, 200
      release(hotkey)
      assert_receive :toggled, 200

      press(hotkey)
      assert_receive :toggled, 200
      release(hotkey)
      assert_receive :toggled, 200
    end
  end

  describe "key filtering" do
    test "a different keycode never arms the timer" do
      hotkey = start_hotkey(self())

      send(hotkey, {:key, 999, 1})

      refute_receive :toggled, 120
    end
  end

  describe "reader errors" do
    test "a reader error is survived and the reader is retried" do
      hotkey = start_hotkey(self(), retry_ms: 20)

      # Simulate the device vanishing: the GenServer must stay alive and reschedule.
      send(hotkey, {:reader_error, :device_not_found})

      Process.sleep(60)
      assert Process.alive?(hotkey)

      # And it still works once a key arrives.
      press(hotkey)
      assert_receive :toggled, 200
    end
  end
end
