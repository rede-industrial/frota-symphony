defmodule SymphonyElixir.WorkflowStore do
  @moduledoc """
  Caches the last known good workflow and reloads it when `WORKFLOW.md` changes.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @poll_interval_ms 1_000

  defmodule State do
    @moduledoc false

    defstruct [:path, :stamp, :workflow, :settings]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current() :: {:ok, Workflow.loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :current)

      _ ->
        Workflow.load()
    end
  end

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :settings)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, %State{settings: settings}} -> {:ok, settings}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec force_reload() :: :ok | {:error, term()}
  def force_reload do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        GenServer.call(__MODULE__, :force_reload)

      _ ->
        case load_state(Workflow.workflow_file_path()) do
          {:ok, _state} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec last_known_good_path(Path.t() | nil) :: Path.t()
  def last_known_good_path(path \\ nil) do
    path = path || Workflow.workflow_file_path()
    Path.join(Path.dirname(path), "WORKFLOW.last-known-good")
  end

  @spec promote_candidate(Path.t(), Path.t(), keyword()) ::
          {:ok, [map()]}
          | {:error, {:preflight_failed, term()}, [map()]}
          | {:error, {:promotion_failed, term()}, [map()]}
          | {:error, {:rolled_back, term()}, [map()]}
          | {:error, {:rollback_failed, term(), term()}, [map()]}
  def promote_candidate(live_path, candidate_path, opts \\ [])
      when is_binary(live_path) and is_binary(candidate_path) and is_list(opts) do
    health_check = Keyword.get(opts, :health_check, fn _path -> :ok end)
    reload = Keyword.get(opts, :reload, fn _path -> :ok end)
    lkg_path = Keyword.get(opts, :last_known_good_path, last_known_good_path(live_path))

    with :ok <- preflight_workflow_path(candidate_path),
         :ok <- preflight_workflow_path(live_path),
         {:ok, audit} <- preserve_last_known_good(live_path, lkg_path, []),
         {:ok, audit} <- promote_candidate_file(live_path, candidate_path, audit),
         :ok <- reload.(live_path) do
      case health_check.(live_path) do
        :ok ->
          {:ok, audit_event(audit, :health_check_passed, %{path: live_path})}

        health_reason ->
          audit = audit_event(audit, :health_check_failed, %{path: live_path, reason: health_reason})
          rollback_after_failed_health(live_path, lkg_path, reload, health_check, health_reason, audit)
      end
    else
      {:preflight_failed, reason} ->
        {:error, {:preflight_failed, reason},
         audit_event([], :workflow_preflight_failed, %{
           candidate_path: candidate_path,
           reason: reason
         })}

      {:promotion_failed, reason, audit} ->
        {:error, {:promotion_failed, reason},
         audit_event(audit, :workflow_promotion_failed, %{
           live_path: live_path,
           reason: reason
         })}

      {:error, reason} ->
        audit =
          audit_event([], :workflow_promotion_failed, %{
            live_path: live_path,
            reason: reason
          })

        {:error, {:promotion_failed, reason}, audit}
    end
  end

  @impl true
  def init(_opts) do
    case load_state(Workflow.workflow_file_path()) do
      {:ok, state} ->
        schedule_poll()
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:current, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.workflow}, new_state}
    end
  end

  def handle_call(:force_reload, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call(:settings, _from, %State{} = state) do
    case reload_state(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}

      {:error, _reason, new_state} ->
        {:reply, {:ok, new_state.settings}, new_state}
    end
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    schedule_poll()

    case reload_state(state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, _reason, new_state} -> {:noreply, new_state}
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp reload_state(%State{} = state) do
    path = Workflow.workflow_file_path()

    if path != state.path do
      reload_path(path, state)
    else
      reload_current_path(path, state)
    end
  end

  defp reload_path(path, state) do
    case load_state(path) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp reload_current_path(path, state) do
    case current_stamp(path) do
      {:ok, stamp} when stamp == state.stamp ->
        {:ok, state}

      {:ok, _stamp} ->
        reload_path(path, state)

      {:error, reason} ->
        log_reload_error(path, reason)
        {:error, reason, state}
    end
  end

  defp load_state(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings),
         {:ok, stamp} <- current_stamp(path) do
      persist_last_known_good(path)
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, settings: settings}}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_workflow_path(path) do
    with {:ok, workflow} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(workflow.config),
         :ok <- Config.validate_settings(settings),
         {:ok, stamp} <- current_stamp(path) do
      {:ok, %State{path: path, stamp: stamp, workflow: workflow, settings: settings}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp preflight_workflow_path(path) do
    case validate_workflow_path(path) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:preflight_failed, reason}
    end
  end

  defp preserve_last_known_good(live_path, lkg_path, audit) do
    case File.cp(live_path, lkg_path) do
      :ok ->
        {:ok, audit_event(audit, :last_known_good_preserved, %{path: lkg_path})}

      {:error, reason} ->
        {:promotion_failed, reason, audit}
    end
  end

  defp promote_candidate_file(live_path, candidate_path, audit) do
    case atomic_replace(live_path, candidate_path) do
      :ok ->
        {:ok, audit_event(audit, :atomic_promotion, %{live_path: live_path, candidate_path: candidate_path})}

      {:error, reason} ->
        {:promotion_failed, reason, audit}
    end
  end

  defp atomic_replace(live_path, source_path) do
    tmp_path = live_path <> ".promote-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.cp(source_path, tmp_path),
         :ok <- File.rename(tmp_path, live_path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp rollback_after_failed_health(live_path, lkg_path, reload, health_check, health_reason, audit) do
    case atomic_replace(live_path, lkg_path) do
      :ok ->
        audit = audit_event(audit, :automatic_rollback, %{live_path: live_path, last_known_good_path: lkg_path})
        _ = reload.(live_path)

        case health_check.(live_path) do
          :ok ->
            audit = audit_event(audit, :rollback_health_check_passed, %{path: live_path})

            {:error, {:rolled_back, health_reason}, audit}

          rollback_reason ->
            {:error, {:rollback_failed, health_reason, rollback_reason},
             audit
             |> audit_event(:rollback_health_check_failed, %{path: live_path, reason: rollback_reason})
             |> audit_event(:fail_closed, %{path: live_path})}
        end

      {:error, rollback_reason} ->
        {:error, {:rollback_failed, health_reason, rollback_reason},
         audit
         |> audit_event(:automatic_rollback_failed, %{path: live_path, reason: rollback_reason})
         |> audit_event(:fail_closed, %{path: live_path})}
    end
  end

  defp audit_event(events, event, metadata) do
    [metadata |> Map.put(:event, event) |> Map.put(:recorded_at, DateTime.utc_now()) | events]
  end

  defp persist_last_known_good(path) do
    lkg_path = last_known_good_path(path)

    case File.cp(path, lkg_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to persist last known good workflow path=#{lkg_path} reason=#{inspect(reason)}")
        :ok
    end
  end

  defp current_stamp(path) when is_binary(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, content} <- File.read(path) do
      {:ok, {stat.mtime, stat.size, :erlang.phash2(content)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp log_reload_error(path, reason) do
    Logger.error("Failed to reload workflow path=#{path} reason=#{inspect(reason)}; keeping last known good configuration")
  end
end
