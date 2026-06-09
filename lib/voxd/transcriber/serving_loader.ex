defmodule Voxd.Transcriber.ServingLoader do
  @moduledoc """
  Loads the speech model in the background after the daemon boots, so voxd
  answers immediately instead of making you wait out the slow model load.

  Loading Whisper and compiling its GPU programs takes several seconds (the
  very first boot, which also compiles from scratch, takes longer). If that
  happened during startup, `voxctl status` would hang. Instead the daemon
  boots fully — socket listening, overlay up — and this one-shot Task does
  the slow part on the side:

  1. Load the model bundle (`Voxd.Transcriber.Bumblebee.load/0`).
  2. Build the final and watcher servings and start each as a named process
     (`Voxd.Serving.Final` / `Voxd.Serving.Watcher`) under the app's serving
     supervisor.
  3. Call `Voxd.Ready.mark_ready/0` — `status` flips from `"loading"` to
     `"idle"` and `/tmp/voxd-ready` appears.

  The Task is `restart: :temporary` in the tree: if the load fails, the
  daemon must stay up. The failure is logged and readiness simply never
  flips — `status` keeps saying `"loading"`, which is your cue to check
  `/tmp/voxd.log`.
  """

  require Logger

  alias Voxd.Ready
  alias Voxd.Transcriber.Bumblebee

  @batch_size 1

  @doc """
  Child spec for the loader Task. `:temporary` — a model-load failure must
  not restart-loop or take the daemon down. `opts` are forwarded to `run/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> run(opts) end]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Load the model, start both servings under `supervisor`, and declare the
  daemon ready. Never raises — a failure is logged and readiness stays off.

  Options:

    * `:supervisor` — the serving `DynamicSupervisor` (default
      `Voxd.ServingSupervisor`).
    * `:ready_file` — path passed to `Voxd.Ready.mark_ready/1` (default the
      real ready file).
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, Voxd.ServingSupervisor)
    ready_file = Keyword.get(opts, :ready_file, Ready.default_ready_file())
    load_and_start(supervisor, ready_file)
  rescue
    error ->
      Logger.error("serving load failed; status stays \"loading\": #{inspect(error)}")
      :ok
  end

  @spec load_and_start(Supervisor.supervisor(), String.t()) :: :ok
  defp load_and_start(supervisor, ready_file) do
    log_loading()
    bundle = Bumblebee.load()
    start_serving(supervisor, Bumblebee.final_serving_name(), Bumblebee.final_serving(bundle))
    start_serving(supervisor, Bumblebee.watcher_serving_name(), Bumblebee.watcher_serving(bundle))
    Ready.mark_ready(ready_file)
    Logger.info("voxd servings ready")
    :ok
  end

  @spec log_loading() :: :ok
  defp log_loading do
    Logger.info("loading whisper model and compiling servings (this is the slow first boot)")
    :ok
  end

  @spec start_serving(Supervisor.supervisor(), module(), Nx.Serving.t()) :: :ok
  defp start_serving(supervisor, name, serving) do
    spec = Nx.Serving.child_spec(serving: serving, name: name, batch_size: @batch_size)
    {:ok, _pid} = DynamicSupervisor.start_child(supervisor, spec)
    :ok
  end
end
