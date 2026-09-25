defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Tracker.Issue
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_required_labels: [],
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          worker_workspace_roots: %{},
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_executables: %{},
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          pilot_enabled: false,
          pilot_issue_ids: [],
          pilot_required_labels: [],
          pilot_capabilities: [],
          pilot_worker_host: nil,
          pilot_ignore_retries: false,
          mission_enabled: false,
          mission_id: nil,
          mission_issue_ids: [],
          retry_guard_enabled: false,
          retry_guard_max_attempts_per_issue: 3,
          finops_guard_enabled: false,
          finops_guard_max_tokens_per_issue: nil,
          finops_guard_max_tokens_per_mission: nil,
          finops_guard_max_turns_per_issue: nil,
          finops_guard_max_retries_per_issue: nil,
          finops_guard_max_observed_tokens: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_required_labels = Keyword.get(config, :tracker_required_labels)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_platforms = Keyword.get(config, :worker_platforms)
    worker_workspace_roots = Keyword.get(config, :worker_workspace_roots)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_executables = Keyword.get(config, :codex_executables)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    pilot_enabled = Keyword.get(config, :pilot_enabled)
    pilot_issue_ids = Keyword.get(config, :pilot_issue_ids)
    pilot_required_labels = Keyword.get(config, :pilot_required_labels)
    pilot_capabilities = Keyword.get(config, :pilot_capabilities)
    pilot_worker_host = Keyword.get(config, :pilot_worker_host)
    pilot_ignore_retries = Keyword.get(config, :pilot_ignore_retries)
    mission_enabled = Keyword.get(config, :mission_enabled)
    mission_id = Keyword.get(config, :mission_id)
    mission_issue_ids = Keyword.get(config, :mission_issue_ids)
    retry_guard_enabled = Keyword.get(config, :retry_guard_enabled)
    retry_guard_max_attempts_per_issue = Keyword.get(config, :retry_guard_max_attempts_per_issue)
    finops_guard_enabled = Keyword.get(config, :finops_guard_enabled)
    finops_guard_max_tokens_per_issue = Keyword.get(config, :finops_guard_max_tokens_per_issue)
    finops_guard_max_tokens_per_mission = Keyword.get(config, :finops_guard_max_tokens_per_mission)
    finops_guard_max_turns_per_issue = Keyword.get(config, :finops_guard_max_turns_per_issue)
    finops_guard_max_retries_per_issue = Keyword.get(config, :finops_guard_max_retries_per_issue)
    finops_guard_max_observed_tokens = Keyword.get(config, :finops_guard_max_observed_tokens)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  required_labels: #{yaml_value(tracker_required_labels)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host, worker_platforms, worker_workspace_roots),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        codex_executables_yaml(codex_executables),
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        pilot_yaml(pilot_enabled, pilot_issue_ids, pilot_required_labels, pilot_capabilities, pilot_worker_host, pilot_ignore_retries),
        mission_yaml(mission_enabled, mission_id, mission_issue_ids),
        retry_guard_yaml(retry_guard_enabled, retry_guard_max_attempts_per_issue),
        finops_guard_yaml(
          finops_guard_enabled,
          finops_guard_max_tokens_per_issue,
          finops_guard_max_tokens_per_mission,
          finops_guard_max_turns_per_issue,
          finops_guard_max_retries_per_issue,
          finops_guard_max_observed_tokens
        ),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp codex_executables_yaml(values) when is_map(values) and map_size(values) > 0 do
    [
      "  executables:",
      values
      |> Enum.map(fn {host, executable} -> "    #{host}: #{yaml_value(executable)}" end)
      |> Enum.join("\n")
    ]
    |> Enum.join("\n")
  end

  defp codex_executables_yaml(_values), do: nil

  defp yaml_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp pilot_yaml(false, [], [], [], nil, false), do: nil

  defp pilot_yaml(enabled, issue_ids, required_labels, capabilities, worker_host, ignore_retries) do
    [
      "pilot:",
      "  enabled: #{yaml_value(enabled)}",
      "  issue_ids: #{yaml_value(issue_ids)}",
      "  required_labels: #{yaml_value(required_labels)}",
      "  capabilities: #{yaml_value(capabilities)}",
      "  worker_host: #{yaml_value(worker_host)}",
      "  ignore_retries: #{yaml_value(ignore_retries)}"
    ]
    |> Enum.join("\n")
  end

  defp mission_yaml(false, nil, []), do: nil

  defp mission_yaml(enabled, id, issue_ids) do
    [
      "mission:",
      "  enabled: #{yaml_value(enabled)}",
      "  id: #{yaml_value(id)}",
      "  issue_ids: #{yaml_value(issue_ids)}"
    ]
    |> Enum.join("\n")
  end

  defp retry_guard_yaml(false, 3), do: nil

  defp retry_guard_yaml(enabled, max_attempts_per_issue) do
    [
      "retry_guard:",
      "  enabled: #{yaml_value(enabled)}",
      "  max_attempts_per_issue: #{yaml_value(max_attempts_per_issue)}"
    ]
    |> Enum.join("\n")
  end

  defp finops_guard_yaml(false, nil, nil, nil, nil, nil), do: nil

  defp finops_guard_yaml(
         enabled,
         max_tokens_per_issue,
         max_tokens_per_mission,
         max_turns_per_issue,
         max_retries_per_issue,
         max_observed_tokens
       ) do
    [
      "finops_guard:",
      "  enabled: #{yaml_value(enabled)}",
      "  max_tokens_per_issue: #{yaml_value(max_tokens_per_issue)}",
      "  max_tokens_per_mission: #{yaml_value(max_tokens_per_mission)}",
      "  max_turns_per_issue: #{yaml_value(max_turns_per_issue)}",
      "  max_retries_per_issue: #{yaml_value(max_retries_per_issue)}",
      "  max_observed_tokens: #{yaml_value(max_observed_tokens)}"
    ]
    |> Enum.join("\n")
  end

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host, platforms, workspace_roots)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host) and platforms in [nil, %{}] and
              workspace_roots in [nil, %{}],
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host, platforms, workspace_roots) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      platforms not in [nil, %{}] && "  platforms: #{yaml_value(platforms)}",
      workspace_roots not in [nil, %{}] && "  workspace_roots: #{yaml_value(workspace_roots)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
