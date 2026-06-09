defmodule Voxd.SignalHandler do
  @moduledoc """
  Makes sure voxd cleans up after itself when the system asks it to quit
  (a `kill` command, a systemd stop, a logout).

  This handler is swapped into the BEAM's signal server so a SIGTERM or
  SIGINT runs voxd's own shutdown routine instead of the default abrupt
  stop. In order, the routine:

  1. releases the microphone (`Voxd.Session.cancel/0`, which tears down the
     `Recorder` — so your Bluetooth headset isn't left stuck in headset mode),
  2. clears the overlay back to idle,
  3. removes the runtime files (`/tmp/voxd.{sock,pid}` and `/tmp/voxd-ready`),
  4. stops the VM in an orderly way with `System.stop(0)` — strictly more
     graceful than the Python daemon's `os._exit`.

  Any other signal gets the BEAM's standard treatment (SIGQUIT halts;
  everything else is ignored), matching `:erl_signal_handler`.

  The cleanup itself (`cleanup/1`) takes injectable collaborators and file
  paths, so it can be unit-tested without sending a real signal or touching
  the real mic, overlay, and `/tmp` files.
  """

  @behaviour :gen_event

  require Logger

  alias Voxd.{Overlay, Session}

  @runtime_files ["/tmp/voxd.sock", "/tmp/voxd.pid", Voxd.Ready.default_ready_file()]

  @doc """
  The runtime files deleted on shutdown (`/tmp/voxd.{sock,pid}` and the
  ready file).
  """
  @spec runtime_files() :: [String.t()]
  def runtime_files, do: @runtime_files

  @doc """
  Run the shutdown cleanup: release the mic, clear the overlay, and delete
  the runtime files. Each step that fails is logged and skipped — cleanup
  always finishes.

  Options (all injectable for tests):

    * `:session_cancel` — zero-argument function; default `&Voxd.Session.cancel/0`.
    * `:overlay_idle` — zero-argument function; default idles `Voxd.Overlay`.
    * `:runtime_files` — paths to delete; default `runtime_files/0`.
  """
  @spec cleanup(keyword()) :: :ok
  def cleanup(opts \\ []) do
    session_cancel = Keyword.get(opts, :session_cancel, &default_session_cancel/0)
    overlay_idle = Keyword.get(opts, :overlay_idle, &default_overlay_idle/0)
    files = Keyword.get(opts, :runtime_files, @runtime_files)

    cancel_session(session_cancel)
    idle_overlay(overlay_idle)
    Enum.each(files, &File.rm/1)
    :ok
  end

  @spec cancel_session((-> any())) :: :ok
  defp cancel_session(session_cancel) do
    session_cancel.()
    :ok
  rescue
    error ->
      Logger.debug("signal cleanup: session cancel failed: #{inspect(error)}")
      :ok
  end

  @spec idle_overlay((-> any())) :: :ok
  defp idle_overlay(overlay_idle) do
    overlay_idle.()
    :ok
  rescue
    error ->
      Logger.debug("signal cleanup: overlay idle failed: #{inspect(error)}")
      :ok
  end

  @spec default_session_cancel() :: any()
  defp default_session_cancel, do: Session.cancel()

  @spec default_overlay_idle() :: any()
  defp default_overlay_idle, do: Overlay.show(Overlay, "idle")

  @impl :gen_event
  def init(_args), do: {:ok, %{}}

  @impl :gen_event
  def handle_event(signal, state) when signal in [:sigterm, :sigint] do
    Logger.info("#{signal} received - shutting down voxd")
    cleanup()
    System.stop(0)
    {:ok, state}
  end

  def handle_event(:sigquit, state) do
    :erlang.halt()
    {:ok, state}
  end

  def handle_event(_signal, state), do: {:ok, state}

  @impl :gen_event
  def handle_info(_info, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def terminate(_args, _state), do: :ok

  @impl :gen_event
  def code_change(_old_vsn, state, _extra), do: {:ok, state}
end
