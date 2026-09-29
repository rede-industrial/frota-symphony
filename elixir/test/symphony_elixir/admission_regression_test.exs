defmodule SymphonyElixir.AdmissionRegressionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.Adapter
  alias SymphonyElixir.Routing
  alias SymphonyElixir.Tracker.Memory

  test "invalid worker platforms and empty roots are rejected before admission" do
    for platform <- ["unsupported", 42] do
      refute Schema.Worker.changeset(%Schema.Worker{}, %{platforms: %{"carla" => platform}}).valid?
    end

    refute Schema.Worker.changeset(%Schema.Worker{}, %{workspace_roots: %{"carla" => ""}}).valid?

    for platform <- ["win32", "cmd", "linux", "unix"] do
      assert Schema.Worker.changeset(%Schema.Worker{}, %{platforms: %{"carla" => platform}}).valid?
    end
  end

  test "blank enabled mission or pilot is rejected while disabled contracts remain valid" do
    refute Schema.Mission.changeset(%Schema.Mission{}, %{enabled: true, id: "   ", issue_ids: []}).valid?
    refute Schema.Pilot.changeset(%Schema.Pilot{}, %{enabled: true, worker_host: "   "}).valid?
    assert Schema.Mission.changeset(%Schema.Mission{}, %{enabled: false}).valid?
    assert Schema.Pilot.changeset(%Schema.Pilot{}, %{enabled: false}).valid?
    assert Schema.KillSwitch.changeset(%Schema.KillSwitch{}, %{enabled: false}).valid?
    refute Schema.KillSwitch.changeset(%Schema.KillSwitch{}, %{enabled: true}).valid?
  end

  test "nonpositive FinOps budgets cannot be admitted and optional budget may be cleared" do
    for value <- [0, -1] do
      refute Schema.FinopsGuard.changeset(%Schema.FinopsGuard{}, %{max_tokens_per_issue: value}).valid?
    end

    guard = %Schema.FinopsGuard{max_tokens_per_issue: 100}
    assert Schema.FinopsGuard.changeset(guard, %{max_tokens_per_issue: nil}).valid?
    assert Schema.Routing.changeset(%Schema.Routing{}, %{canonical_file: "/tmp/routes.json"}).valid?
  end

  test "duplicate completion receipt cannot duplicate a delivered session" do
    issue = %Issue{id: "admission-regression", identifier: "GH-regression"}
    completion = %{session_id: "same-session", terminal_transition: "none"}
    old = Application.get_env(:symphony_elixir, :memory_tracker_completions)

    on_exit(fn ->
      if is_nil(old),
        do: Application.delete_env(:symphony_elixir, :memory_tracker_completions),
        else: Application.put_env(:symphony_elixir, :memory_tracker_completions, old)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_completions, [])
    assert {:ok, _} = Memory.persist_completion(issue, completion)
    assert {:ok, _} = Memory.persist_completion(issue, completion)
    assert length(Application.get_env(:symphony_elixir, :memory_tracker_completions)) == 1
  end

  test "malformed and ambiguous routing cannot select a worker" do
    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "canonical-routing.json")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, "{}")
    assert {:error, :invalid_route_table} = Routing.worker_for_issue(%Issue{id: "1", labels: []})

    table = %{
      "remote_destinations" => %{"carla" => %{}},
      "routes" => [
        %{"capability" => "BACKEND_ENGINEERING", "destination_id" => "carla"},
        %{"capability" => "BACKEND_ENGINEERING", "destination_id" => "carla"},
        %{"irrelevant" => true}
      ]
    }

    File.write!(path, Jason.encode!(table))
    assert :local_allowed = Routing.worker_for_issue(%Issue{id: "1", labels: []})
    assert {:error, :ambiguous_capability} = Routing.worker_for_issue(%Issue{id: "1", labels: ["capability:backend-engineering"]})
    assert {:error, :ambiguous_capability} = Routing.worker_for_issue(%Issue{id: "1", labels: ["capability:backend-engineering", "capability:infra-devops"]})
  end

  test "failure to preserve last known good denies promotion without changing live workflow" do
    dir = Path.dirname(Workflow.workflow_file_path())
    live = Path.join(dir, "admission-live.md")
    candidate = Path.join(dir, "admission-candidate.md")
    write_workflow_file!(live, tracker_kind: "memory")
    write_workflow_file!(candidate, tracker_kind: "memory", poll_interval_ms: 12_345)
    before = File.read!(live)

    assert {:error, {:promotion_failed, :enoent}, audit} =
             WorkflowStore.promote_candidate(live, candidate, last_known_good_path: Path.join([dir, "missing-parent", "lkg.md"]))

    assert File.read!(live) == before
    assert Enum.any?(audit, &(&1.event == :workflow_promotion_failed))
    assert is_binary(WorkflowStore.last_known_good_path())
  end

  test "disabled mission and pilot clear nullable values without admitting work" do
    mission = %Schema.Mission{id: "old", issue_ids: ["GH-1"]}
    cs = Schema.Mission.changeset(mission, %{enabled: false, id: nil, issue_ids: nil})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :issue_ids) == []

    capabilities = ["BACKEND_ENGINEERING"]
    pilot = %Schema.Pilot{worker_host: "carla", issue_ids: ["GH-1"], capabilities: capabilities, required_labels: ["safe"]}
    cleared = %{enabled: false, worker_host: nil, issue_ids: nil, capabilities: nil, required_labels: nil}
    cs = Schema.Pilot.changeset(pilot, cleared)
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :worker_host) == nil
    assert Ecto.Changeset.get_field(cs, :capabilities) == []

    cs = Schema.Codex.changeset(%Schema.Codex{}, %{executables: %{"carla" => "", "pedro" => "   "}})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :executables) == %{}
    cs = Schema.Codex.changeset(%Schema.Codex{executables: %{"carla" => "old"}}, %{executables: nil})
    assert cs.valid?
    assert Ecto.Changeset.get_field(cs, :executables) == %{}
  end

  test "read-only live directory denies atomic promotion and preserves live bytes" do
    dir = Path.join(Path.dirname(Workflow.workflow_file_path()), "readonly-live")
    File.mkdir_p!(dir)
    on_exit(fn -> File.chmod(dir, 0o755) end)
    live = Path.join(dir, "live.md")
    candidate = Path.join(Path.dirname(dir), "readonly-candidate.md")
    lkg = Path.join(Path.dirname(dir), "readonly-lkg.md")
    write_workflow_file!(live, tracker_kind: "memory")
    write_workflow_file!(candidate, tracker_kind: "memory", poll_interval_ms: 12_345)
    before = File.read!(live)
    File.chmod!(dir, 0o555)

    assert {:error, {:promotion_failed, :eacces}, audit} =
             WorkflowStore.promote_candidate(live, candidate, last_known_good_path: lkg)

    assert File.read!(live) == before
    assert File.read!(lkg) == before
    assert Enum.any?(audit, &(&1.event == :workflow_promotion_failed))
    File.chmod!(dir, 0o755)
  end

  test "loss of rollback artifact is fail-closed and recorded" do
    dir = Path.dirname(Workflow.workflow_file_path())
    live = Path.join(dir, "lost-lkg-live.md")
    candidate = Path.join(dir, "lost-lkg-candidate.md")
    lkg = Path.join(dir, "lost-lkg.md")
    write_workflow_file!(live, tracker_kind: "memory")
    write_workflow_file!(candidate, tracker_kind: "memory", poll_interval_ms: 12_345)

    health = fn _ ->
      File.rm!(lkg)
      {:error, :unhealthy}
    end

    assert {:error, {:rollback_failed, {:error, :unhealthy}, :enoent}, audit} =
             WorkflowStore.promote_candidate(live, candidate, last_known_good_path: lkg, health_check: health)

    assert Enum.any?(audit, &(&1.event == :automatic_rollback_failed))
    assert Enum.any?(audit, &(&1.event == :fail_closed))
  end

  defmodule ReceiptClient do
    def persist_completion(issue, completion), do: {:error, {issue.id, completion.session_id}}
  end

  test "receipt persistence failure is propagated rather than reported as success" do
    previous = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:symphony_elixir, :github_client_module),
        else: Application.put_env(:symphony_elixir, :github_client_module, previous)
    end)

    Application.put_env(:symphony_elixir, :github_client_module, ReceiptClient)

    assert {:error, {"receipt", "session"}} =
             Adapter.persist_completion(%Issue{id: "receipt"}, %{session_id: "session"})
  end

  test "Windows commissioning instructions follow worker platform and do not leak to Linux" do
    issue = %Issue{id: "platform", identifier: "GH-platform"}

    for platform <- ["windows", "win32", "cmd", "linux"] do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        pilot_enabled: true,
        pilot_issue_ids: ["GH-platform"],
        pilot_capabilities: ["BACKEND_ENGINEERING"],
        pilot_worker_host: "carla",
        worker_platforms: %{"carla" => platform}
      )

      prompt = SymphonyElixir.PromptBuilder.build_prompt(issue, worker_host: "carla")
      assert String.contains?(prompt, "Remote Windows commissioning contract") == (platform != "linux")
      other = SymphonyElixir.PromptBuilder.build_prompt(issue, worker_host: "unmapped")
      refute String.contains?(other, "Remote Windows commissioning contract")
    end
  end

  test "SSH stdin without stderr merging uses the supplied executable and preserves output" do
    dir = Path.join(Path.dirname(Workflow.workflow_file_path()), "fake-ssh-stdin")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "ssh"), "#!/bin/sh\ndd bs=1 count=7 2>/dev/null\n")
    File.chmod!(Path.join(dir, "ssh"), 0o755)
    old = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", old) end)
    System.put_env("PATH", dir <> ":" <> old)
    assert {:ok, {"receipt", 0}} = SymphonyElixir.SSH.run("test-only", "ignored", input: "receipt")
  end

  test "explicit canonical routing path is loaded from the workflow" do
    path = Path.join(Path.dirname(Workflow.workflow_file_path()), "explicit-routes.json")
    File.write!(path, Jason.encode!(%{"routes" => [], "remote_destinations" => %{}}))
    workflow = Workflow.workflow_file_path()
    write_workflow_file!(workflow, tracker_kind: "memory")
    content = String.replace(File.read!(workflow), "---\n", "---\nrouting:\n  canonical_file: " <> path <> "\n", global: false)
    File.write!(workflow, content)
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{"routes" => []}} = Routing.route_table()
  end

  test "reload failure cannot report workflow promotion success" do
    dir = Path.dirname(Workflow.workflow_file_path())
    live = Path.join(dir, "reload-live.md")
    candidate = Path.join(dir, "reload-candidate.md")
    write_workflow_file!(live, tracker_kind: "memory")
    write_workflow_file!(candidate, tracker_kind: "memory", poll_interval_ms: 12_345)

    assert {:error, {:promotion_failed, :reload_denied}, audit} =
             WorkflowStore.promote_candidate(live, candidate, reload: fn _ -> {:error, :reload_denied} end)

    assert Enum.any?(audit, &(&1.event == :workflow_promotion_failed))
  end

  test "unwritable last known good destination is observed without losing loaded state" do
    path = WorkflowStore.last_known_good_path()
    File.rm!(path)
    File.mkdir!(path)
    on_exit(fn -> File.rmdir(path) end)
    assert {:ok, _state} = WorkflowStore.init([])
    File.rmdir!(path)
  end
end
