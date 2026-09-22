defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "worker" => worker_context(opts) |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> append_remote_windows_pilot_contract(opts)
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp worker_context(opts) do
    %{
      host: Keyword.get(opts, :worker_host),
      workspace: Keyword.get(opts, :workspace)
    }
  end

  defp append_remote_windows_pilot_contract(prompt, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    if remote_windows_pilot?(worker_host) do
      prompt <> remote_windows_pilot_contract(worker_host, Keyword.get(opts, :workspace))
    else
      prompt
    end
  end

  defp remote_windows_pilot?(worker_host) when is_binary(worker_host) and worker_host != "" do
    settings = Config.settings!()

    settings.pilot.enabled and windows_worker_platform?(Map.get(settings.worker.platforms, worker_host))
  end

  defp remote_windows_pilot?(_worker_host), do: false

  defp windows_worker_platform?(platform) when platform in [:windows, :windows_cmd], do: true

  defp windows_worker_platform?(platform) when is_binary(platform) do
    platform
    |> String.trim()
    |> String.downcase()
    |> case do
      "windows" -> true
      "win32" -> true
      "windows_cmd" -> true
      "cmd" -> true
      _ -> false
    end
  end

  defp windows_worker_platform?(_platform), do: false

  defp remote_windows_pilot_contract(worker_host, workspace) do
    """

    Remote Windows commissioning contract:

    - The orchestrator already routed this work to worker_host=#{worker_host}.
    - The orchestrator already prepared the remote workspace: #{workspace || "unknown"}.
    - The Codex app-server for this turn is already remote.
    - This pilot must not require PowerShell.
    - Do not run PowerShell commands.
    - Do not request shell approval for commissioning evidence.
    - Keep all work inside the prepared workspace using normal workspace file reads/writes.
    - If a shell command is unavoidable, use only non-administrative cmd.exe semantics; if that would request approval, stop and report BLOCKERS=REQUEST_APPROVAL_REQUIRED.
    - For a safe commissioning pilot, return the structured result from the issue context and the worker context above instead of probing host identity with shell commands.
    """
  end
end
