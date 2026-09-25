defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Tracker.Issue

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec persist_completion(Issue.t(), map()) :: {:ok, map()} | {:error, term()}
  def persist_completion(%Issue{} = issue, completion) when is_map(completion) do
    if Application.get_env(:symphony_elixir, :memory_tracker_completion_fail, false) do
      {:error, :memory_completion_failed}
    else
      completion_record = %{
        issue_id: issue.id,
        identifier: issue.identifier,
        completion: completion,
        persisted_at: DateTime.utc_now()
      }

      completions = Application.get_env(:symphony_elixir, :memory_tracker_completions, [])
      marker = {issue.id, completion[:session_id]}

      updated =
        if Enum.any?(completions, fn entry -> {entry.issue_id, entry.completion[:session_id]} == marker end) do
          completions
        else
          [completion_record | completions]
        end

      Application.put_env(:symphony_elixir, :memory_tracker_completions, updated)

      {:ok,
       %{
         tracker: "memory",
         issue_id: issue.id,
         terminal_transition: completion[:terminal_transition] || "none"
       }}
    end
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(_tracker_settings), do: []

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
