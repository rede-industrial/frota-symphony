defmodule SymphonyElixir.Routing do
  @moduledoc false

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Tracker.Issue

  @type decision ::
          {:ok, String.t()}
          | :local_allowed
          | {:error,
             :unknown_capability
             | :ambiguous_capability
             | :missing_destination
             | :unknown_worker
             | :invalid_route_table}

  @spec worker_for_issue(Issue.t()) :: decision()
  def worker_for_issue(%Issue{} = issue) do
    with {:ok, route_table} when not is_nil(route_table) <- route_table(),
         {:ok, capability} <- issue_capability(issue),
         {:ok, destination} <- destination_for_capability(route_table, capability),
         :ok <- known_worker?(route_table, destination) do
      {:ok, destination}
    else
      {:ok, nil} -> :local_allowed
      :no_capability -> :local_allowed
      {:error, reason} -> {:error, reason}
    end
  end

  @spec route_table() :: {:ok, map()} | {:error, term()}
  def route_table do
    path = canonical_file_path()

    if is_nil(path) do
      {:ok, nil}
    else
      with {:ok, body} <- File.read(path),
           {:ok, decoded} <- Jason.decode(body),
           :ok <- validate_route_table(decoded) do
        {:ok, decoded}
      end
    end
  end

  defp canonical_file_path do
    case Config.settings!().routing.canonical_file do
      path when is_binary(path) and path != "" ->
        workflow_dir = Workflow.workflow_file_path() |> Path.expand() |> Path.dirname()
        Path.expand(path, workflow_dir)

      _ ->
        default_path =
          Workflow.workflow_file_path()
          |> Path.expand()
          |> Path.dirname()
          |> Path.join("canonical-routing.json")

        if File.exists?(default_path), do: default_path, else: nil
    end
  end

  defp validate_route_table(%{"routes" => routes, "remote_destinations" => destinations})
       when is_list(routes) and is_map(destinations),
       do: :ok

  defp validate_route_table(_), do: {:error, :invalid_route_table}

  defp issue_capability(%Issue{labels: labels}) do
    capabilities =
      labels
      |> List.wrap()
      |> Enum.map(&label_capability/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case capabilities do
      [] -> :no_capability
      [capability] -> {:ok, capability}
      _ -> {:error, :ambiguous_capability}
    end
  end

  defp label_capability("capability:" <> capability), do: normalize_capability(capability)
  defp label_capability(_), do: nil

  defp destination_for_capability(%{"routes" => routes}, capability) do
    matches =
      Enum.filter(routes, fn
        %{"capability" => route_capability} -> normalize_capability(route_capability) == capability
        _ -> false
      end)

    case matches do
      [%{"destination_id" => destination}] when is_binary(destination) and destination != "" ->
        {:ok, destination}

      [_] ->
        {:error, :missing_destination}

      [] ->
        {:error, :unknown_capability}

      _ ->
        {:error, :ambiguous_capability}
    end
  end

  defp known_worker?(%{"remote_destinations" => destinations}, destination) do
    if Map.has_key?(destinations, destination), do: :ok, else: {:error, :unknown_worker}
  end

  defp normalize_capability(capability) when is_binary(capability) do
    capability
    |> String.trim()
    |> String.replace("-", "_")
    |> String.upcase()
  end
end
