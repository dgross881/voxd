defmodule Voxd.Transcriber.ServingLoader do
  @moduledoc """
  A one-shot Task (child of the app tree) that brings the transcription servings
  online **after** boot, so the control socket can accept connections and report
  `"loading"` the whole time the ~1.5 GB model loads and the two XLA graphs
  compile.

  It loads the model bundle (`Voxd.Transcriber.Bumblebee.load/0`), builds the
  final and watcher servings, starts each as a named `Nx.Serving` process
  (`Voxd.Serving.Final` / `Voxd.Serving.Watcher`, `batch_size: 1`) under the
  app's serving `DynamicSupervisor`, then `Voxd.Ready.mark_ready/0` so `status`
  flips to `"idle"` and `/tmp/voxd-ready` appears.

  The Task is `restart: :temporary` in the tree: a load failure must not take the
  daemon down. It logs and leaves readiness `false` (status stays `"loading"`).
  """

  require Logger

  alias Voxd.Ready
  alias Voxd.Transcriber.Bumblebee

  @batch_size 1

  @doc """
  Child spec for the loader Task. `:temporary` — a model-load failure must not
  restart-loop or crash the daemon. `opts` are forwarded to `run/1`.
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
  Load the model, start both servings under `supervisor`, and mark ready.

  Options:

    * `:supervisor` — the serving `DynamicSupervisor` (default
      `Voxd.ServingSupervisor`).
    * `:ready_file` — path passed to `Voxd.Ready.mark_ready/1` (default the real
      ready file).
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
