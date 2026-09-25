defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    assert config.tracker.assignee == nil
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Review,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "   ",
      tracker_project_slug: "project"
    )

    assert {:error, :missing_linear_api_token} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: ""
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  test "MISSION_ALLOWLIST_PASS only mission issues are dispatch candidates" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      mission_enabled: true,
      mission_id: "FROTA-INAUGURAL-SIGMAWEB-V2-AUDIT-20260924",
      mission_issue_ids: ["GH-136", "GH-137"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    allowed = %Issue{
      id: "GH-136",
      identifier: "GH-136",
      title: "Mission issue",
      state: "Todo",
      dispatchable: true
    }

    denied = %Issue{
      id: "GH-38",
      identifier: "GH-38",
      title: "Old backlog",
      state: "Todo",
      dispatchable: true
    }

    assert Orchestrator.should_dispatch_issue_for_test(allowed, state)
    refute Orchestrator.should_dispatch_issue_for_test(denied, state)
  end

  test "OLD_BACKLOG_DENIED_PASS mission rejects historical backlog even when otherwise active" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      mission_enabled: true,
      mission_id: "FROTA-INAUGURAL-SIGMAWEB-V2-AUDIT-20260924",
      mission_issue_ids: ["GH-136", "GH-137", "GH-138", "GH-139", "GH-140", "GH-141", "GH-142"]
    )

    old_backlog = %Issue{
      id: "GH-74",
      identifier: "GH-74",
      title: "Historical backlog must stay out",
      state: "In Progress",
      dispatchable: true
    }

    refute Orchestrator.mission_issue_allowed_for_test(old_backlog)
  end

  test "PILOT_CONTRACT_PRESERVED_PASS pilot remains exactly one issue and one capability" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pilot_enabled: true,
      pilot_issue_ids: ["GH-136"],
      pilot_capabilities: ["SYSTEM_ANALYSIS"],
      pilot_worker_host: "norma"
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pilot_enabled: true,
      pilot_issue_ids: ["GH-136", "GH-137"],
      pilot_capabilities: ["SYSTEM_ANALYSIS"],
      pilot_worker_host: "norma"
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "pilot.issue_ids"
  end

  test "AMBIGUOUS_MODE_FAIL_CLOSED_PASS mission and pilot cannot both be active" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pilot_enabled: true,
      pilot_issue_ids: ["GH-136"],
      pilot_capabilities: ["SYSTEM_ANALYSIS"],
      pilot_worker_host: "norma",
      mission_enabled: true,
      mission_id: "FROTA-INAUGURAL-SIGMAWEB-V2-AUDIT-20260924",
      mission_issue_ids: ["GH-136", "GH-137"]
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "mission"
    assert message =~ "cannot be enabled when pilot is enabled"
  end

  test "RETRY_STORM_POSSIBLE=NO attempt 4 is blocked without a new retry timer" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      retry_guard_enabled: true,
      retry_guard_max_attempts_per_issue: 3
    )

    base_state = %Orchestrator.State{
      retry_attempts: %{},
      blocked: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    issue = %Issue{id: "GH-136", identifier: "GH-136", url: "https://example.test/GH-136"}

    allowed_attempts =
      for attempt <- [1, 2, 3] do
        Orchestrator.schedule_issue_retry_for_test(base_state, "GH-136", attempt, %{
          identifier: "GH-136",
          issue: issue,
          issue_url: issue.url,
          error: "synthetic failure"
        })
      end

    assert Enum.all?(Enum.zip([1, 2, 3], allowed_attempts), fn {attempt, state} ->
             get_in(state.retry_attempts, ["GH-136", :attempt]) == attempt and
               !Map.has_key?(state.blocked, "GH-136")
           end)

    blocked_state =
      Orchestrator.schedule_issue_retry_for_test(base_state, "GH-136", 4, %{
        identifier: "GH-136",
        issue: issue,
        issue_url: issue.url,
        error: "synthetic failure"
      })

    refute Map.has_key?(blocked_state.retry_attempts, "GH-136")
    assert get_in(blocked_state.blocked, ["GH-136", :error]) =~ "retry_guard"
    assert %DateTime{} = get_in(blocked_state.blocked, ["GH-136", :blocked_at])
  end

  test "FINOPS circuit breaker opens locally and denies dispatch" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      finops_guard_enabled: true,
      finops_guard_max_observed_tokens: 10,
      finops_guard_max_tokens_per_mission: 10,
      finops_guard_max_retries_per_issue: 3
    )

    state = %Orchestrator.State{
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 10, seconds_running: 0},
      running: %{},
      claimed: MapSet.new(),
      blocked: %{}
    }

    issue = %Issue{id: "GH-136", identifier: "GH-136", title: "Mission", state: "Todo", dispatchable: true}

    assert {:open, reason} = Orchestrator.finops_circuit_open_for_test(state, issue, 1)
    assert reason == "max_observed_tokens exceeded"

    retry_blocked =
      Orchestrator.schedule_issue_retry_for_test(state, "GH-136", 1, %{
        identifier: "GH-136",
        issue: issue,
        issue_url: "https://example.test/GH-136",
        error: "would retry"
      })

    assert retry_blocked.finops_circuit.status == :open
    refute Map.has_key?(retry_blocked.retry_attempts, "GH-136")
    assert get_in(retry_blocked.blocked, ["GH-136", :error]) == "max_observed_tokens exceeded"
  end

  test "AG001_ISSUE_BUDGET_BREAKER enforces per-issue budget without killing Symphony" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      finops_guard_enabled: true,
      finops_guard_max_tokens_per_issue: 10
    )

    issue = ag001_issue()
    allowed_state = ag001_finops_state(running: %{"GH-136" => ag001_running_entry(issue, codex_total_tokens: 9)})
    exceeded_state = ag001_finops_state(running: %{"GH-136" => ag001_running_entry(issue, codex_total_tokens: 10)})

    assert :closed = Orchestrator.finops_circuit_open_for_test(allowed_state, issue, 1)
    assert {:open, "max_tokens_per_issue exceeded"} = Orchestrator.finops_circuit_open_for_test(exceeded_state, issue, 1)

    assert_ag001_finops_excess_blocks_dispatch_and_retry(exceeded_state, issue, "max_tokens_per_issue exceeded")
  end

  test "AG001_MISSION_BUDGET_BREAKER enforces mission budget without killing Symphony" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      finops_guard_enabled: true,
      finops_guard_max_tokens_per_mission: 10
    )

    issue = ag001_issue()
    allowed_state = ag001_finops_state(codex_total_tokens: 9)
    exceeded_state = ag001_finops_state(codex_total_tokens: 10)

    assert :closed = Orchestrator.finops_circuit_open_for_test(allowed_state, issue, 1)
    assert {:open, "max_tokens_per_mission exceeded"} = Orchestrator.finops_circuit_open_for_test(exceeded_state, issue, 1)

    assert_ag001_finops_excess_blocks_dispatch_and_retry(exceeded_state, issue, "max_tokens_per_mission exceeded")
  end

  test "AG001_TURN_BUDGET_BREAKER enforces turn budget without killing Symphony" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      finops_guard_enabled: true,
      finops_guard_max_turns_per_issue: 4
    )

    issue = ag001_issue()
    allowed_state = ag001_finops_state(running: %{"GH-136" => ag001_running_entry(issue, turn_count: 3)})
    exceeded_state = ag001_finops_state(running: %{"GH-136" => ag001_running_entry(issue, turn_count: 4)})

    assert :closed = Orchestrator.finops_circuit_open_for_test(allowed_state, issue, 1)
    assert {:open, "max_turns_per_issue exceeded"} = Orchestrator.finops_circuit_open_for_test(exceeded_state, issue, 1)

    assert_ag001_finops_excess_blocks_dispatch_and_retry(exceeded_state, issue, "max_turns_per_issue exceeded")
  end

  test "AG001_RETRY_BUDGET_BREAKER enforces FinOps retry budget without killing Symphony" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      finops_guard_enabled: true,
      finops_guard_max_retries_per_issue: 3
    )

    issue = ag001_issue()
    state = ag001_finops_state()

    assert :closed = Orchestrator.finops_circuit_open_for_test(state, issue, 3)
    assert {:open, "max_retries_per_issue exceeded"} = Orchestrator.finops_circuit_open_for_test(state, issue, 4)

    assert_ag001_finops_excess_blocks_dispatch_and_retry(state, issue, "max_retries_per_issue exceeded", 4)
  end

  test "AG001_ACCUMULATED_BUDGET_BREAKER enforces observed Symphony budget without killing Symphony" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      finops_guard_enabled: true,
      finops_guard_max_observed_tokens: 10
    )

    issue = ag001_issue()
    allowed_state = ag001_finops_state(codex_total_tokens: 9)
    exceeded_state = ag001_finops_state(codex_total_tokens: 10)

    assert :closed = Orchestrator.finops_circuit_open_for_test(allowed_state, issue, 1)
    assert {:open, "max_observed_tokens exceeded"} = Orchestrator.finops_circuit_open_for_test(exceeded_state, issue, 1)

    assert_ag001_finops_excess_blocks_dispatch_and_retry(exceeded_state, issue, "max_observed_tokens exceeded")
  end

  test "AG001_RETRY_STORM_DENIED blocks attempt 4 without a Codex call" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      retry_guard_enabled: true,
      retry_guard_max_attempts_per_issue: 3
    )

    issue = ag001_issue()
    state = ag001_finops_state()

    blocked_state =
      Orchestrator.schedule_issue_retry_for_test(state, "GH-136", 4, %{
        identifier: issue.identifier,
        issue: issue,
        issue_url: issue.url,
        error: "synthetic retry storm"
      })

    refute Map.has_key?(blocked_state.retry_attempts, "GH-136")
    assert blocked_state.running == state.running
    assert get_in(blocked_state.blocked, ["GH-136", :error]) =~ "retry_guard"
    assert Enum.any?(blocked_state.audit_events, &(&1.event == :issue_blocked))
    assert Process.alive?(self())
  end

  test "AG001_BACKLOG_OUTSIDE_MISSION_DENIED rejects issues outside mission allowlist" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      mission_enabled: true,
      mission_id: "FROTA-INAUGURAL-SIGMAWEB-V2-AUDIT-20260924",
      mission_issue_ids: ["GH-136", "GH-137", "GH-138", "GH-139", "GH-140", "GH-141", "GH-142"]
    )

    refute Orchestrator.mission_issue_allowed_for_test(%Issue{
             id: "GH-74",
             identifier: "GH-74",
             title: "Historical backlog",
             state: "Todo",
             dispatchable: true
           })
  end

  test "AG001_INVALID_WORKFLOW_DENIED keeps live workflow unchanged" do
    workflow_dir = Workflow.workflow_file_path() |> Path.dirname()
    live_path = Path.join(workflow_dir, "WORKFLOW.live")
    candidate_path = Path.join(workflow_dir, "WORKFLOW.candidate")
    lkg_path = Path.join(workflow_dir, "WORKFLOW.invalid-candidate.last-known-good")

    write_workflow_file!(live_path, tracker_kind: "memory", poll_interval_ms: 31_000)
    live_before = File.read!(live_path)

    write_workflow_file!(candidate_path,
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, {:preflight_failed, :missing_linear_project_slug}, audit} =
             WorkflowStore.promote_candidate(live_path, candidate_path, last_known_good_path: lkg_path)

    assert File.read!(live_path) == live_before
    refute File.exists?(lkg_path)
    assert Enum.any?(audit, &(&1.event == :workflow_preflight_failed))
  end

  test "AG001_WORKFLOW_HEALTH_ROLLBACK restores LKG and rechecks health" do
    workflow_dir = Workflow.workflow_file_path() |> Path.dirname()
    live_path = Path.join(workflow_dir, "WORKFLOW.live")
    candidate_path = Path.join(workflow_dir, "WORKFLOW.candidate")

    write_workflow_file!(live_path, tracker_kind: "memory", poll_interval_ms: 31_000)
    write_workflow_file!(candidate_path, tracker_kind: "memory", poll_interval_ms: 45_000)

    live_before = File.read!(live_path)
    candidate_content = File.read!(candidate_path)

    health_check = fn path ->
      if File.read!(path) == candidate_content, do: {:error, :unhealthy_candidate}, else: :ok
    end

    assert {:error, {:rolled_back, {:error, :unhealthy_candidate}}, audit} =
             WorkflowStore.promote_candidate(live_path, candidate_path, health_check: health_check)

    assert File.read!(live_path) == live_before
    assert File.read!(WorkflowStore.last_known_good_path(live_path)) == live_before
    assert Enum.any?(audit, &(&1.event == :last_known_good_preserved))
    assert Enum.any?(audit, &(&1.event == :atomic_promotion))
    assert Enum.any?(audit, &(&1.event == :health_check_failed))
    assert Enum.any?(audit, &(&1.event == :automatic_rollback))
    assert Enum.any?(audit, &(&1.event == :rollback_health_check_passed))
  end

  test "AG001_LKG_RECOVERY keeps valid candidate on health pass and fail-closes rollback health failure" do
    workflow_dir = Workflow.workflow_file_path() |> Path.dirname()
    live_path = Path.join(workflow_dir, "WORKFLOW.live")
    candidate_path = Path.join(workflow_dir, "WORKFLOW.candidate")

    write_workflow_file!(live_path, tracker_kind: "memory", poll_interval_ms: 31_000)
    write_workflow_file!(candidate_path, tracker_kind: "memory", poll_interval_ms: 45_000)

    live_before = File.read!(live_path)
    candidate_content = File.read!(candidate_path)

    assert {:ok, pass_audit} = WorkflowStore.promote_candidate(live_path, candidate_path)
    assert File.read!(live_path) == candidate_content
    assert File.read!(WorkflowStore.last_known_good_path(live_path)) == live_before
    assert Enum.any?(pass_audit, &(&1.event == :health_check_passed))

    write_workflow_file!(candidate_path, tracker_kind: "memory", poll_interval_ms: 60_000)

    assert {:error, {:rollback_failed, {:error, :candidate_unhealthy}, {:error, :rollback_unhealthy}}, fail_audit} =
             WorkflowStore.promote_candidate(live_path, candidate_path,
               health_check: fn path ->
                 if File.read!(path) == File.read!(candidate_path),
                   do: {:error, :candidate_unhealthy},
                   else: {:error, :rollback_unhealthy}
               end
             )

    assert File.read!(live_path) == candidate_content
    assert Enum.any?(fail_audit, &(&1.event == :rollback_health_check_failed))
    assert Enum.any?(fail_audit, &(&1.event == :fail_closed))
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)

    System.put_env("LINEAR_API_KEY", "test-linear-api-key")
    Workflow.clear_workflow_file_path()

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(get_in(tracker, ["provider", "project_slug"]))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "after_create") =~ "git clone --depth 1 https://github.com/openai/symphony ."
    assert Map.get(hooks, "after_create") =~ "cd elixir && mise trust"
    assert Map.get(hooks, "after_create") =~ "mise exec -- mix deps.get"
    assert Map.get(hooks, "before_remove") =~ "cd elixir && mise exec -- mix workspace.before_remove"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
  end

  test "linear api token resolves from LINEAR_API_KEY env var" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.api_key == env_api_key
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory when app env is unset" do
    original_workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.clear_workflow_file_path()

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} =
             Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} =
             Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link starts the agent runtime" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    runtime_pid = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    on_exit(fn ->
      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        case Supervisor.restart_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(runtime_pid) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) == pid
    assert is_pid(Process.whereis(SymphonyElixir.TaskSupervisor))
    assert is_pid(Process.whereis(SymphonyElixir.Orchestrator))

    GenServer.stop(pid)
  end

  test "orchestrator fails startup when semantic preflight fails" do
    issue_suffix = System.unique_integer([:positive])
    orchestrator_name = Module.concat(__MODULE__, "InvalidOrchestrator#{issue_suffix}")
    workflow_path = Workflow.workflow_file_path()

    on_exit(fn ->
      if pid = Process.whereis(orchestrator_name) do
        GenServer.stop(pid)
      end

      write_workflow_file!(workflow_path, tracker_kind: "memory")

      if is_nil(Process.whereis(WorkflowStore)) do
        assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      end

      if is_nil(Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)) do
        assert {:ok, _pid} =
                 Supervisor.restart_child(
                   SymphonyElixir.Supervisor,
                   SymphonyElixir.AgentRuntimeSupervisor
                 )
      end
    end)

    assert :ok =
             Supervisor.terminate_child(
               SymphonyElixir.Supervisor,
               SymphonyElixir.AgentRuntimeSupervisor
             )

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error, :missing_linear_project_slug} =
             Orchestrator.start_link(name: orchestrator_name)

    Process.flag(:trap_exit, previous_trap_exit)

    refute Process.whereis(orchestrator_name)
  end

  test "runtime restart keeps last good settings after an invalid reload" do
    issue_suffix = System.unique_integer([:positive])
    runtime_supervisor_name = Module.concat(__MODULE__, "ReloadRuntime#{issue_suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "ReloadTaskSupervisor#{issue_suffix}")
    orchestrator_name = Module.concat(__MODULE__, "ReloadOrchestrator#{issue_suffix}")

    on_exit(fn ->
      if pid = Process.whereis(runtime_supervisor_name) do
        GenServer.stop(pid)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    lkg_path = WorkflowStore.last_known_good_path(Workflow.workflow_file_path())
    assert File.exists?(lkg_path)
    lkg_content = File.read!(lkg_path)

    assert {:ok, runtime_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_supervisor_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_pid)
    original_orchestrator_pid = Process.whereis(orchestrator_name)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_project_slug} = Config.validate!()
    assert Config.settings!().tracker.kind == "memory"
    assert File.read!(lkg_path) == lkg_content

    Process.exit(original_orchestrator_pid, :kill)

    restarted_orchestrator_pid =
      eventually_value(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != original_orchestrator_pid ->
            case Orchestrator.snapshot(orchestrator_name, 100) do
              %{} -> pid
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    assert is_pid(restarted_orchestrator_pid)
    assert Process.whereis(orchestrator_name) == restarted_orchestrator_pid
    assert Process.alive?(runtime_pid)
  end

  test "restarting the orchestrator does not overlap redispatched work" do
    issue_suffix = System.unique_integer([:positive])

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-restart-#{issue_suffix}"
      )

    hook_marker = Path.join(test_root, "before-run-started")
    hook_fifo = Path.join(test_root, "before-run-blocker")
    hook_pids = Path.join(test_root, "before-run-pids")
    runtime_supervisor_name = Module.concat(__MODULE__, "AgentRuntimeSupervisor#{issue_suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "TaskSupervisor#{issue_suffix}")
    orchestrator_name = Module.concat(__MODULE__, "RestartOrchestrator#{issue_suffix}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    issue = %Issue{
      id: "issue-restart-#{issue_suffix}",
      identifier: "MT-#{issue_suffix}",
      title: "Restart an in-flight worker",
      description: "Keep one worker active while the orchestrator restarts",
      state: "In Progress",
      url: "https://example.org/issues/MT-#{issue_suffix}",
      labels: [],
      dispatchable: true
    }

    on_exit(fn ->
      release_fifo_reader(hook_fifo)

      if pid = Process.whereis(runtime_supervisor_name) do
        GenServer.stop(pid)
      end

      terminate_recorded_pids(hook_pids)
      terminate_test_root_processes(test_root)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restart_default_runtime!()
      File.rm_rf(test_root)
    end)

    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      assert :ok =
               Supervisor.terminate_child(
                 SymphonyElixir.Supervisor,
                 SymphonyElixir.AgentRuntimeSupervisor
               )
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: test_root,
      poll_interval_ms: 10,
      hook_before_run: "echo $$ >> \"#{hook_pids}\"; [ -p \"#{hook_fifo}\" ] || mkfifo \"#{hook_fifo}\"; : > \"#{hook_marker}\"; read _ < \"#{hook_fifo}\"",
      hook_timeout_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:ok, runtime_supervisor_pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_supervisor_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    Process.unlink(runtime_supervisor_pid)

    orchestrator_pid = Process.whereis(orchestrator_name)
    task_supervisor_pid = Process.whereis(task_supervisor_name)

    assert is_pid(orchestrator_pid)
    assert is_pid(task_supervisor_pid)

    first_worker_pid =
      eventually_value(fn ->
        case Task.Supervisor.children(task_supervisor_name) do
          [pid] -> pid
          _ -> nil
        end
      end)

    assert is_pid(first_worker_pid)
    assert Process.alive?(first_worker_pid)
    assert eventually_value(fn -> if File.exists?(hook_marker), do: true end)

    monitor_ref = Process.monitor(orchestrator_pid)
    Process.exit(orchestrator_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^orchestrator_pid, :killed}, 1_000

    restarted_pid =
      eventually_value(fn ->
        case Process.whereis(orchestrator_name) do
          pid when is_pid(pid) and pid != orchestrator_pid -> pid
          _ -> nil
        end
      end)

    restarted_task_supervisor_pid =
      eventually_value(fn ->
        case Process.whereis(task_supervisor_name) do
          pid when is_pid(pid) and pid != task_supervisor_pid -> pid
          _ -> nil
        end
      end)

    assert is_pid(restarted_pid)
    assert is_pid(restarted_task_supervisor_pid)
    assert is_map(GenServer.call(restarted_pid, :snapshot))
    refute Process.alive?(first_worker_pid)

    second_worker_pid =
      eventually_value(fn ->
        children = Task.Supervisor.children(task_supervisor_name)
        assert length(children) <= 1

        case children do
          [pid] when pid != first_worker_pid -> pid
          _ -> nil
        end
      end)

    assert is_pid(second_worker_pid)
    assert Process.alive?(second_worker_pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent before cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)
    worker_alive_marker = Path.join(test_root, "worker-alive")
    cleanup_marker = Path.join(test_root, "cleanup-order")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        hook_before_remove: "if [ -f \"#{worker_alive_marker}\" ]; then printf alive > \"#{cleanup_marker}\"; else printf stopped > \"#{cleanup_marker}\"; fi"
      )

      File.mkdir_p!(workspace)
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      {:ok, agent_pid} =
        Task.Supervisor.start_child(task_supervisor, fn ->
          Process.flag(:trap_exit, true)
          File.write!(worker_alive_marker, "alive")

          try do
            receive do
              {:EXIT, _from, :shutdown} -> :ok
            end
          after
            File.rm(worker_alive_marker)
          end
        end)

      assert eventually_value(fn -> if File.exists?(worker_alive_marker), do: true end)

      state = %Orchestrator.State{
        task_supervisor: task_supervisor,
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.read!(cleanup_marker) == "stopped"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal cleanup uses the workspace recorded for the running issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-recorded-workspace-#{System.unique_integer([:positive])}"
      )

    old_root = Path.join(test_root, "old-root")
    new_root = Path.join(test_root, "new-root")
    issue_id = "issue-recorded-workspace"
    issue_identifier = "MT-557"
    old_workspace = Path.join(old_root, issue_identifier)
    new_workspace = Path.join(new_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: old_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(old_workspace)
      File.mkdir_p!(new_workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
            workspace_path: old_workspace,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: new_root)

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Done",
        description: "Completed",
        labels: []
      }

      _updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute File.exists?(old_workspace)
      assert File.exists?(new_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress", "In Review"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Progress", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Progress",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: [],
      dispatchable: true
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Progress"
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Progress",
            dispatchable: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Progress",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      dispatchable: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile stops running issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "issue-unlabeled"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-562",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-562",
            state: "In Progress",
            labels: ["symphony"]
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-562",
      state: "In Progress",
      title: "Opted out active issue",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "reconcile releases a blocked issue when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "blocked-unlabeled"

    state = %Orchestrator.State{
      blocked: %{
        issue_id => %{
          identifier: "MT-564",
          error: "operator input required",
          worker_host: nil
        }
      },
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-564",
      title: "Blocked but opted out",
      state: "In Progress",
      labels: []
    }

    updated_state = Orchestrator.reconcile_blocked_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.blocked, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
  end

  test "retry releases its claim when a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue_id = "retry-unlabeled"

    state = %Orchestrator.State{
      claimed: MapSet.new([issue_id]),
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-565",
      title: "Retry opted out",
      state: "In Progress",
      labels: []
    }

    updated_state =
      Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
        identifier: issue.identifier,
        error: "agent exited"
      })

    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Map.has_key?(updated_state.retry_attempts, issue_id)
  end

  test "retry releases its claim when dispatch revalidation no longer finds the issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-retry-refresh-#{System.unique_integer([:positive])}"
      )

    issue_id = "retry-refreshed-issue"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        hook_before_run: "exit 1"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      {:ok, task_supervisor} = Task.Supervisor.start_link()

      state = %Orchestrator.State{
        task_supervisor: task_supervisor,
        claimed: MapSet.new([issue_id]),
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: "MT-566",
        title: "Retry refreshed issue",
        state: "In Progress",
        dispatchable: true,
        labels: []
      }

      updated_state =
        Orchestrator.handle_retry_issue_lookup_for_test(issue, state, issue_id, 1, %{
          identifier: issue.identifier,
          error: "agent exited"
        })

      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.running, issue_id)
      refute Map.has_key?(updated_state.retry_attempts, issue_id)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner does not continue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    issue = %Issue{
      id: "issue-label-continuation",
      identifier: "MT-563",
      title: "Stop after opt-out",
      state: "In Progress",
      labels: ["symphony"]
    }

    refreshed_issue = %{issue | labels: []}
    fetcher = fn ["issue-label-continuation"] -> {:ok, [refreshed_issue]} end

    assert {:done, ^refreshed_issue} =
             AgentRunner.continue_with_issue_for_test(issue, fetcher)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_in_range(due_at_ms, 500, 1_100)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 39_500, 40_500)
  end

  test "pilot mode dispatches only the allowlisted issue and capability" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["p0-factory-loop-1x1-20260921"],
      pilot_enabled: true,
      pilot_issue_ids: ["101"],
      pilot_required_labels: ["p0-factory-loop-1x1-20260921"],
      pilot_capabilities: ["BACKEND_ENGINEERING"],
      pilot_worker_host: "carla",
      pilot_ignore_retries: true,
      worker_ssh_hosts: ["carla"],
      worker_max_concurrent_agents_per_host: 1,
      max_concurrent_agents: 1
    )

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), blocked: %{}, max_concurrent_agents: 1}

    allowed = %Issue{
      id: "101",
      identifier: "GH-101",
      title: "Pilot issue",
      state: "Todo",
      labels: ["p0-factory-loop-1x1-20260921", "capability:backend-engineering"],
      dispatchable: true
    }

    wrong_issue = %{allowed | id: "102", identifier: "GH-102"}
    wrong_capability = %{allowed | labels: ["p0-factory-loop-1x1-20260921", "capability:frontend-engineering"]}
    missing_pilot_label = %{allowed | labels: ["capability:backend-engineering"]}

    assert Orchestrator.should_dispatch_issue_for_test(allowed, state)
    refute Orchestrator.should_dispatch_issue_for_test(wrong_issue, state)
    refute Orchestrator.should_dispatch_issue_for_test(wrong_capability, state)
    refute Orchestrator.should_dispatch_issue_for_test(missing_pilot_label, state)
    assert Orchestrator.select_worker_host_for_test(state, nil) == "carla"
  end

  test "pilot mode skips startup terminal workspace cleanup" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["p0-factory-loop-1x1-20260921"],
      pilot_enabled: true,
      pilot_issue_ids: ["issue-pilot-cleanup"],
      pilot_required_labels: ["p0-factory-loop-1x1-20260921"],
      pilot_capabilities: ["BACKEND_ENGINEERING"],
      pilot_worker_host: "carla",
      pilot_ignore_retries: true,
      worker_ssh_hosts: ["carla", "vitoria"],
      worker_max_concurrent_agents_per_host: 1,
      max_concurrent_agents: 1
    )

    refute Orchestrator.startup_terminal_workspace_cleanup_enabled_for_test()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["p0-factory-loop-1x1-20260921"],
      pilot_enabled: false,
      worker_ssh_hosts: ["carla", "vitoria"],
      worker_max_concurrent_agents_per_host: 1,
      max_concurrent_agents: 1
    )

    assert Orchestrator.startup_terminal_workspace_cleanup_enabled_for_test()
  end

  test "pilot mode blocks failed worker exits instead of retrying" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["p0-factory-loop-1x1-20260921"],
      pilot_enabled: true,
      pilot_issue_ids: ["issue-pilot-retry"],
      pilot_required_labels: ["p0-factory-loop-1x1-20260921"],
      pilot_capabilities: ["BACKEND_ENGINEERING"],
      pilot_worker_host: "carla",
      pilot_ignore_retries: true,
      worker_ssh_hosts: ["carla"],
      worker_max_concurrent_agents_per_host: 1,
      max_concurrent_agents: 1
    )

    issue_id = "issue-pilot-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :PilotRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "GH-101",
      issue: %Issue{id: issue_id, identifier: "GH-101", state: "open"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert state.retry_attempts == %{}
    assert MapSet.member?(state.claimed, issue_id)
    assert state.running == %{}

    assert %{
             issue_id: ^issue_id,
             identifier: "GH-101",
             error: "agent exited: :boom"
           } = state.blocked[issue_id]
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} =
             state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, 9_000, 10_500)
  end

  test "stale retry timer messages do not consume newer retry entries" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} =
             Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "canonical routing maps capabilities to exact remote workers and denies unknowns" do
    workflow_dir = Workflow.workflow_file_path() |> Path.dirname()
    routing_file = Path.join(workflow_dir, "canonical-routing.json")

    File.write!(
      routing_file,
      Jason.encode!(%{
        "remote_destinations" => %{
          "vitoria" => %{"host_alias" => "vitoria"},
          "carla" => %{"host_alias" => "carla"},
          "pedro" => %{"host_alias" => "pedro"}
        },
        "routes" => [
          %{"capability" => "FRONTEND_ENGINEERING", "destination_id" => "vitoria"},
          %{"capability" => "BACKEND_ENGINEERING", "destination_id" => "carla"},
          %{"capability" => "INFRA_DEVOPS", "destination_id" => "pedro"}
        ]
      })
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony-safe-pilot-20260911"],
      worker_ssh_hosts: ["vitoria", "carla", "pedro"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), blocked: %{}, max_concurrent_agents: 1}

    frontend = routed_issue("frontend", "capability:frontend-engineering")
    backend = routed_issue("backend", "capability:backend-engineering")
    infra = routed_issue("infra", "capability:infra-devops")
    unknown = routed_issue("unknown", "capability:unknown")

    assert Orchestrator.routed_worker_host_for_test(state, frontend) == "vitoria"
    assert Orchestrator.routed_worker_host_for_test(state, backend) == "carla"
    assert Orchestrator.routed_worker_host_for_test(state, infra) == "pedro"
    assert Orchestrator.routed_worker_host_for_test(state, unknown) == {:deny, :unknown_capability}

    assert Orchestrator.should_dispatch_issue_for_test(frontend, state)
    refute Orchestrator.should_dispatch_issue_for_test(unknown, state)
  end

  test "canonical routing denies missing destinations and prevents local fallback" do
    workflow_dir = Workflow.workflow_file_path() |> Path.dirname()
    routing_file = Path.join(workflow_dir, "canonical-routing.json")

    File.write!(
      routing_file,
      Jason.encode!(%{
        "remote_destinations" => %{"vitoria" => %{"host_alias" => "vitoria"}},
        "routes" => [
          %{"capability" => "FRONTEND_ENGINEERING", "destination_id" => "missing-worker"},
          %{"capability" => "BACKEND_ENGINEERING"}
        ]
      })
    )

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony-safe-pilot-20260911"],
      worker_ssh_hosts: [],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{running: %{}, claimed: MapSet.new(), blocked: %{}, max_concurrent_agents: 1}

    frontend = routed_issue("frontend", "capability:frontend-engineering")
    backend = routed_issue("backend", "capability:backend-engineering")

    assert Orchestrator.routed_worker_host_for_test(state, frontend) == {:deny, :unknown_worker}
    assert Orchestrator.routed_worker_host_for_test(state, backend) == {:deny, :missing_destination}
    refute Orchestrator.should_dispatch_issue_for_test(frontend, state)
    refute Orchestrator.should_dispatch_issue_for_test(backend, state)
  end

  test "windows cmd workers prepare native workspaces without bash or WSL" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/tmp/local-symphony-workspaces",
      worker_ssh_hosts: ["vitoria"],
      worker_platforms: %{"vitoria" => "windows_cmd"},
      worker_workspace_roots: %{"vitoria" => "C:\\FROTA\\symphony-workspaces"},
      hook_after_create: "git clone https://github.com/rede-industrial/frota-control-center.git ."
    )

    assert {:ok, "C:\\FROTA\\symphony-workspaces\\GH-119"} =
             Workspace.workspace_path_for_issue_for_test("GH-119", "vitoria")

    script =
      "C:\\FROTA\\symphony-workspaces\\GH-119"
      |> Workspace.workspace_prepare_command_for_test(:windows_cmd)

    wrapped = SymphonyElixir.SSH.remote_shell_command(script, :windows_cmd)

    assert wrapped =~ "cmd.exe /d /s /c"
    assert script =~ "mkdir C:\\FROTA\\symphony-workspaces\\GH-119"
    assert script =~ "cd /d C:\\FROTA\\symphony-workspaces\\GH-119"
    assert script =~ "__SYMPHONY_WORKSPACE__"
    assert script =~ ".symphony-workspace"
    assert script =~ "rmdir /s /q C:\\FROTA\\symphony-workspaces\\GH-119"
    assert script =~ "workspace exists and is not an initialized Symphony workspace"
    assert script =~ "git -C C:\\FROTA\\symphony-workspaces\\GH-119 config --get remote.origin.url"
    assert script =~ "findstr /x /c:\"https://github.com/rede-industrial/frota-control-center.git\""
    refute String.contains?(script, "rmdir /s /q C:\\FROTA\\symphony-workspaces ")
    refute String.contains?(script, "%created%")
    refute String.contains?(script, "%CD%")
    refute String.contains?(String.downcase(wrapped), "bash")
    refute String.contains?(String.downcase(wrapped), "wsl")
    refute String.contains?(String.downcase(wrapped), "powershell")
  end

  test "linux worker prepare keeps the existing bash transport" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      worker_ssh_hosts: ["linux-a"],
      worker_platforms: %{"linux-a" => "posix"}
    )

    assert {:ok, "/remote/workspaces/GH-200"} =
             Workspace.workspace_path_for_issue_for_test("GH-200", "linux-a")

    script = Workspace.workspace_prepare_command_for_test("/remote/workspaces/GH-200", :posix)
    wrapped = SymphonyElixir.SSH.remote_shell_command(script, :posix)

    assert wrapped =~ "bash -lc"
    assert script =~ "mkdir -p \"$workspace\""
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  defp routed_issue(id, capability_label) do
    %Issue{
      id: id,
      identifier: "GH-#{id}",
      title: "Routed #{id}",
      state: "Todo",
      labels: ["symphony-safe-pilot-20260911", capability_label],
      dispatchable: true
    }
  end

  defp assert_due_in_range(due_at_ms, min_remaining_ms, max_remaining_ms) do
    remaining_ms = due_at_ms - System.monotonic_time(:millisecond)

    assert remaining_ms >= min_remaining_ms
    assert remaining_ms <= max_remaining_ms
  end

  defp release_fifo_reader(path) do
    if File.exists?(path) do
      task =
        Task.async(fn ->
          File.write(path, "\n")
        end)

      Task.yield(task, 100) || Task.shutdown(task, :brutal_kill)
    end

    :ok
  end

  defp terminate_recorded_pids(path) do
    path
    |> read_recorded_pids()
    |> Enum.each(&terminate_recorded_pid/1)
  end

  defp read_recorded_pids(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split()
        |> Enum.flat_map(fn value ->
          case Integer.parse(value) do
            {pid, ""} -> [pid]
            _ -> []
          end
        end)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

  defp terminate_recorded_pid(pid) when is_integer(pid) do
    System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    :ok
  end

  defp terminate_test_root_processes(test_root) do
    case System.cmd("pgrep", ["-f", test_root], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split()
        |> Enum.flat_map(fn value ->
          case Integer.parse(value) do
            {pid, ""} -> [pid]
            _ -> []
          end
        end)
        |> Enum.each(&terminate_recorded_pid/1)

      {_output, _status} ->
        :ok
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restart_default_runtime! do
    if Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      :ok =
        Supervisor.terminate_child(
          SymphonyElixir.Supervisor,
          SymphonyElixir.AgentRuntimeSupervisor
        )
    end

    case Supervisor.restart_child(
           SymphonyElixir.Supervisor,
           SymphonyElixir.AgentRuntimeSupervisor
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp eventually_value(fun, attempts \\ 100)

  defp eventually_value(_fun, 0), do: nil

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt =
      "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on an issue from the configured tracker."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Title: Make fallback prompt useful"
    assert prompt =~ "Body:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Title: Handle empty body"
    assert prompt =~ "No description provided."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)

    System.put_env("LINEAR_API_KEY", "test-linear-api-key")
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Progress",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~ "You are working on a Linear ticket `MT-616`"
    assert prompt =~ "Issue context:"
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ "Title: Use rich templates for WORKFLOW.md"
    assert prompt =~ "Current status: In Progress"
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"
    assert prompt =~ "This is an unattended orchestration session."
    assert prompt =~ "Only stop early for a true external blocker"
    assert prompt =~ "Do not include \"next steps for user\""
    assert prompt =~ "open and follow `.codex/skills/land/SKILL.md`"
    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "Follow-up context:"
    assert prompt =~ "follow-up attempt #2"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "prompt builder adds remote windows pilot contract without weakening approval policy" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Handle {{ issue.identifier }} on {{ worker.host }} in {{ worker.workspace }}.",
      worker_ssh_hosts: ["vitoria"],
      worker_platforms: %{"vitoria" => "windows_cmd"},
      pilot_enabled: true,
      pilot_issue_ids: ["120"],
      pilot_required_labels: ["symphony-safe-pilot-20260911"],
      pilot_capabilities: ["FRONTEND_ENGINEERING"],
      pilot_worker_host: "vitoria",
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write"
    )

    issue = %Issue{
      identifier: "GH-120",
      title: "Vitoria commissioning",
      description: "Produce structured proof without privileged commands.",
      state: "open",
      url: "https://github.com/rede-industrial/frota-control-center/issues/120",
      labels: ["symphony-safe-pilot-20260911", "capability:frontend-engineering"]
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        worker_host: "vitoria",
        workspace: "C:\\FROTA\\symphony-workspaces\\GH-120"
      )

    assert prompt =~ "Handle GH-120 on vitoria in C:\\FROTA\\symphony-workspaces\\GH-120."
    assert prompt =~ "Remote Windows commissioning contract:"
    assert prompt =~ "worker_host=vitoria"
    assert prompt =~ "This pilot must not require PowerShell."
    assert prompt =~ "Do not run PowerShell commands."
    assert prompt =~ "Do not request shell approval"
    assert prompt =~ "normal workspace file reads/writes"
    assert prompt =~ "return the structured result from the issue context"
    refute prompt =~ "hostname\nwhoami\ncd\ngit status"

    assert Config.settings!().codex.approval_policy == "on-request"
    assert Config.settings!().codex.thread_sandbox == "workspace-write"
  end

  test "prompt builder does not add remote windows pilot contract outside pilot mode" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Handle {{ issue.identifier }}.",
      worker_ssh_hosts: ["vitoria"],
      worker_platforms: %{"vitoria" => "windows_cmd"},
      pilot_enabled: false
    )

    issue = %Issue{
      identifier: "GH-121",
      title: "Normal work",
      description: "No pilot contract",
      state: "open",
      url: "https://github.com/rede-industrial/frota-control-center/issues/121",
      labels: ["capability:frontend-engineering"]
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        worker_host: "vitoria",
        workspace: "C:\\FROTA\\symphony-workspaces\\GH-121"
      )

    refute prompt =~ "Remote Windows commissioning contract:"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created =
        MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"],
        worker_platforms: %{"worker-a" => "posix", "worker-b" => "posix"}
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state,
             dispatchable: true
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "You are an agent for this repository."
      refute Enum.at(turn_texts, 1) =~ "You are an agent for this repository."
      assert Enum.at(turn_texts, 1) =~ "Continuation guidance:"
      assert Enum.at(turn_texts, 1) =~ "continuation turn #2 of 3"
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Progress",
             dispatchable: true
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Progress",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --config 'model=\"gpt-5.5\"' app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--config model=\"gpt-5.5\" app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp ag001_issue do
    %Issue{
      id: "GH-136",
      identifier: "GH-136",
      title: "AG-001 guarded issue",
      state: "Todo",
      url: "https://example.test/GH-136",
      dispatchable: true
    }
  end

  defp ag001_finops_state(opts \\ []) do
    total_tokens = Keyword.get(opts, :codex_total_tokens, 0)

    %Orchestrator.State{
      max_concurrent_agents: 1,
      running: Keyword.get(opts, :running, %{}),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: total_tokens,
        seconds_running: 0
      }
    }
  end

  defp ag001_running_entry(issue, opts) do
    %{
      issue: issue,
      identifier: issue.identifier,
      worker_host: "norma",
      workspace_path: "/tmp/ag001",
      session_id: "session-ag001",
      codex_total_tokens: Keyword.get(opts, :codex_total_tokens, 0),
      turn_count: Keyword.get(opts, :turn_count, 0)
    }
  end

  defp assert_ag001_finops_excess_blocks_dispatch_and_retry(state, issue, reason, attempt \\ 1) do
    dispatch_blocked = Orchestrator.dispatch_issue_for_test(state, issue, attempt)

    assert dispatch_blocked.finops_circuit.status == :open
    assert dispatch_blocked.finops_circuit.reason == reason
    assert dispatch_blocked.running == state.running
    assert get_in(dispatch_blocked.blocked, [issue.id, :error]) == reason
    assert Enum.any?(dispatch_blocked.audit_events, &(&1.event == :issue_blocked and &1.reason == reason))

    retry_blocked =
      Orchestrator.schedule_issue_retry_for_test(state, issue.id, attempt, %{
        identifier: issue.identifier,
        issue: issue,
        issue_url: issue.url,
        error: "synthetic FinOps excess"
      })

    refute Map.has_key?(retry_blocked.retry_attempts, issue.id)
    assert retry_blocked.finops_circuit.status == :open
    assert retry_blocked.finops_circuit.reason == reason
    assert retry_blocked.running == state.running
    assert get_in(retry_blocked.blocked, [issue.id, :error]) == reason
    assert Enum.any?(retry_blocked.audit_events, &(&1.event == :issue_blocked and &1.reason == reason))
    assert Process.alive?(self())
  end
end
