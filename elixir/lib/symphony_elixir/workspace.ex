defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = workspace_key(issue_or_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          :ok ->
            {:ok, workspace}

          {:error, _reason} = error ->
            cleanup_failed_new_workspace(workspace, created?, worker_host)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script = workspace_prepare_script(workspace, worker_platform(worker_host))

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            remove_local_workspace(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script = remove_workspace_script(workspace, worker_platform(worker_host))

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @doc false
  @spec remove_recorded(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_recorded(workspace, nil) when is_binary(workspace) do
    if Path.type(workspace) == :absolute do
      case validate_recorded_workspace_path(workspace) do
        :ok ->
          remove_local_workspace(workspace)

        {:error, reason} ->
          {:error, reason, ""}
      end
    else
      {:error, {:workspace_path_unreadable, workspace, :not_absolute}, ""}
    end
  end

  def remove_recorded(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    remove(workspace, worker_host)
  end

  def remove_recorded(workspace, _worker_host) do
    {:error, {:workspace_path_unreadable, workspace, :invalid}, ""}
  end

  defp remove_local_workspace(workspace) do
    maybe_run_before_remove_hook(workspace, nil)
    File.rm_rf(workspace)
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, worker_host)
      when is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(issue), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(%{id: _issue_id, identifier: _identifier} = issue, nil) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(issue), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    case workspace_path_for_issue(workspace_key(identifier), worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(workspace_key(identifier), nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host), do: :ok

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.local_workspace_root()
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    platform = worker_platform(worker_host)
    root = worker_workspace_root(worker_host)
    {:ok, remote_path_join(root, safe_id, platform)}
  end

  @doc false
  @spec workspace_path_for_issue_for_test(String.t(), worker_host()) :: {:ok, Path.t()} | {:error, term()}
  def workspace_path_for_issue_for_test(safe_id, worker_host), do: workspace_path_for_issue(safe_id, worker_host)

  @doc false
  @spec workspace_prepare_command_for_test(Path.t(), atom()) :: String.t()
  def workspace_prepare_command_for_test(workspace, platform) do
    workspace_prepare_script(workspace, platform)
  end

  @doc """
  Returns the collision-safe directory name for an issue identifier.

  The hash is derived from the original identifier so callers that only know the identifier can
  derive the same key as callers holding a full tracker issue.
  """
  @spec workspace_key(map() | String.t() | nil) :: String.t()
  def workspace_key(%{identifier: identifier}), do: workspace_key(identifier)

  def workspace_key(identifier) when is_binary(identifier) do
    safe_identifier = safe_identifier(identifier)

    if safe_identifier == identifier do
      safe_identifier
    else
      "#{safe_identifier}--#{short_identifier_hash(identifier)}"
    end
  end

  def workspace_key(_identifier), do: "issue"

  defp safe_identifier(identifier) when is_binary(identifier),
    do: String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")

  defp short_identifier_hash(identifier) do
    :crypto.hash(:sha256, identifier)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, nil) do
    case File.rm_rf(workspace) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning("Failed to remove partial workspace path=#{path} reason=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, worker_host) when is_binary(worker_host) do
    script = remove_workspace_script(workspace, worker_platform(worker_host))

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      result ->
        Logger.warning("Failed to remove partial workspace worker_host=#{worker_host_for_log(worker_host)} result=#{inspect(result)}")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script = before_remove_hook_script(command, workspace, worker_platform(worker_host))

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, hook_script(command, workspace, worker_platform(worker_host)), timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Config.local_workspace_root())
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_recorded_workspace_path(workspace) when is_binary(workspace) do
    validate_local_workspace_path(workspace, Path.dirname(workspace))
  end

  defp validate_local_workspace_path(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#\\~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp workspace_prepare_script(workspace, :windows) do
    escaped_workspace = powershell_single_quote(workspace)

    [
      "$ErrorActionPreference = 'Stop'",
      "$workspace = #{escaped_workspace}",
      "$created = '0'",
      "if (Test-Path -LiteralPath $workspace -PathType Leaf) { Write-Error 'workspace path exists and is not a directory'; exit 17 }",
      "if (-not (Test-Path -LiteralPath $workspace -PathType Container)) { New-Item -ItemType Directory -Force -Path $workspace | Out-Null; $created = '1' } else { $children = @(Get-ChildItem -LiteralPath $workspace -Force -ErrorAction Stop); if ($children.Count -eq 0) { $created = '1' } elseif (Test-Path -LiteralPath (Join-Path $workspace '.git') -PathType Container) { $created = '0' } else { Write-Error 'workspace exists and is not empty; refusing to run after_create'; exit 17 } }",
      "$resolved = (Resolve-Path -LiteralPath $workspace).Path",
      "Set-Location -LiteralPath $resolved",
      "Write-Output ('#{@remote_workspace_marker}' + [char]9 + $created + [char]9 + $resolved)"
    ]
    |> Enum.join("; ")
  end

  defp workspace_prepare_script(workspace, :windows_cmd) do
    path_arg = windows_cmd_path_arg(workspace)
    path_quoted = windows_cmd_quote(workspace)
    marker = @remote_workspace_marker
    sentinel = ".symphony-workspace"
    expected_origin = expected_git_origin_from_after_create()

    reusable_git_workspace_script =
      windows_cmd_reusable_git_workspace_script(workspace, expected_origin)

    mark_workspace_script =
      "echo prepared-by=symphony>#{path_arg}\\#{sentinel}"

    create_workspace_script =
      "mkdir #{path_arg} && #{mark_workspace_script} && cd /d #{path_arg} && echo #{marker}\t1\t#{workspace}"

    recreate_marked_partial_workspace_script =
      "rmdir /s /q #{path_arg} && mkdir #{path_arg} && #{mark_workspace_script} && cd /d #{path_arg} && echo #{marker}\t1\t#{workspace}"

    empty_workspace_script =
      "#{mark_workspace_script} && cd /d #{path_arg} && echo #{marker}\t1\t#{workspace}"

    marked_partial_script =
      "if exist #{path_arg}\\#{sentinel} (#{recreate_marked_partial_workspace_script}) else (echo workspace exists and is not an initialized Symphony workspace; refusing to clean 1>&2 & exit /b 17)"

    existing_directory_script =
      "if exist #{path_arg}\\.git\\NUL (#{reusable_git_workspace_script}) else (dir /a /b #{path_quoted} 2>nul | findstr . >nul && (#{marked_partial_script}) || (#{empty_workspace_script}))"

    "if exist #{path_arg}\\NUL (#{existing_directory_script}) else (if exist #{path_arg} (echo workspace path exists and is not a directory 1>&2 & exit /b 17) else (#{create_workspace_script}))"
  end

  defp workspace_prepare_script(workspace, _platform) do
    [
      "set -eu",
      remote_shell_assign("workspace", workspace),
      "if [ -d \"$workspace\" ]; then",
      "  created=0",
      "elif [ -e \"$workspace\" ]; then",
      "  rm -rf \"$workspace\"",
      "  mkdir -p \"$workspace\"",
      "  created=1",
      "else",
      "  mkdir -p \"$workspace\"",
      "  created=1",
      "fi",
      "cd \"$workspace\"",
      "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp remove_workspace_script(workspace, :windows) do
    "if (Test-Path -LiteralPath #{powershell_single_quote(workspace)}) { Remove-Item -LiteralPath #{powershell_single_quote(workspace)} -Recurse -Force }"
  end

  defp remove_workspace_script(workspace, :windows_cmd) do
    "if exist #{windows_cmd_quote(workspace)} rmdir /s /q #{windows_cmd_quote(workspace)}"
  end

  defp remove_workspace_script(workspace, _platform) do
    [remote_shell_assign("workspace", workspace), "rm -rf \"$workspace\""] |> Enum.join("\n")
  end

  defp before_remove_hook_script(command, workspace, :windows) do
    "if (Test-Path -LiteralPath #{powershell_single_quote(workspace)} -PathType Container) { Set-Location -LiteralPath #{powershell_single_quote(workspace)}; #{command} }"
  end

  defp before_remove_hook_script(command, workspace, :windows_cmd) do
    "if exist #{windows_cmd_quote(workspace)}\\* (pushd #{windows_cmd_quote(workspace)} && #{command} & popd)"
  end

  defp before_remove_hook_script(command, workspace, _platform) do
    [
      remote_shell_assign("workspace", workspace),
      "if [ -d \"$workspace\" ]; then",
      "  cd \"$workspace\"",
      "  #{command}",
      "fi"
    ]
    |> Enum.join("\n")
  end

  defp hook_script(command, workspace, :windows) do
    "Set-Location -LiteralPath #{powershell_single_quote(workspace)}; #{command}"
  end

  defp hook_script(command, workspace, :windows_cmd) do
    "pushd #{windows_cmd_quote(workspace)} && #{command} & popd"
  end

  defp hook_script(command, workspace, _platform) do
    "cd #{shell_escape(workspace)} && #{command}"
  end

  defp worker_platform(worker_host) when is_binary(worker_host) do
    Config.settings!().worker.platforms
    |> Map.get(worker_host)
    |> normalize_worker_platform()
  end

  defp normalize_worker_platform(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "windows" -> :windows
      "win32" -> :windows
      "windows_cmd" -> :windows_cmd
      "cmd" -> :windows_cmd
      _ -> :posix
    end
  end

  defp normalize_worker_platform(_value), do: :posix

  defp worker_workspace_root(worker_host) when is_binary(worker_host) do
    Config.settings!().worker.workspace_roots
    |> Map.get(worker_host)
    |> case do
      root when is_binary(root) and root != "" -> root
      _ -> Config.settings!().workspace.root
    end
  end

  defp remote_path_join(root, safe_id, platform) when platform in [:windows, :windows_cmd] do
    String.trim_trailing(root, "\\/") <> "\\" <> safe_id
  end

  defp remote_path_join(root, safe_id, _platform), do: Path.join(root, safe_id)

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] ->
            normalized_path = trim_remote_line_ending(path)

            if normalized_path != "" do
              {created == "1", normalized_path}
            end

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp trim_remote_line_ending(value) when is_binary(value) do
    value
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true, remote_platform: worker_platform(worker_host))
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp powershell_single_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp windows_cmd_path_arg(value) when is_binary(value) do
    if String.match?(value, ~r/[\s&()^%!,;=\[\]{}]/) do
      windows_cmd_quote(value)
    else
      value
    end
  end

  defp windows_cmd_quote(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp windows_cmd_reusable_git_workspace_script(workspace, nil) do
    path_arg = windows_cmd_path_arg(workspace)
    "cd /d #{path_arg} && echo #{@remote_workspace_marker}\t0\t#{workspace}"
  end

  defp windows_cmd_reusable_git_workspace_script(workspace, expected_origin) when is_binary(expected_origin) do
    path_arg = windows_cmd_path_arg(workspace)
    origin_arg = windows_cmd_findstr_literal(expected_origin)

    "git -C #{path_arg} config --get remote.origin.url | findstr /x /c:#{origin_arg} >nul && (cd /d #{path_arg} && echo #{@remote_workspace_marker}\t0\t#{workspace}) || (echo workspace git origin mismatch; refusing to reuse 1>&2 & exit /b 17)"
  end

  defp windows_cmd_findstr_literal(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp expected_git_origin_from_after_create do
    Config.settings!().hooks.after_create
    |> extract_git_clone_origin()
  rescue
    _ -> nil
  end

  defp extract_git_clone_origin(command) when is_binary(command) do
    command
    |> command_words()
    |> find_git_clone_origin()
  end

  defp extract_git_clone_origin(_command), do: nil

  defp command_words(command) do
    ~r/"([^"]*)"|'([^']*)'|(\S+)/
    |> Regex.scan(command)
    |> Enum.map(fn
      [_match, double, "", ""] -> double
      [_match, "", single, ""] -> single
      [_match, "", "", bare] -> bare
    end)
  end

  defp find_git_clone_origin(["git", "clone" | args]), do: git_clone_origin_arg(args)
  defp find_git_clone_origin([_word | rest]), do: find_git_clone_origin(rest)
  defp find_git_clone_origin([]), do: nil

  defp git_clone_origin_arg(["--depth", _value | rest]), do: git_clone_origin_arg(rest)
  defp git_clone_origin_arg(["--branch", _value | rest]), do: git_clone_origin_arg(rest)
  defp git_clone_origin_arg(["-b", _value | rest]), do: git_clone_origin_arg(rest)
  defp git_clone_origin_arg([<<"--", _rest::binary>> | rest]), do: git_clone_origin_arg(rest)
  defp git_clone_origin_arg([repo | _rest]) when is_binary(repo) and repo != ".", do: repo
  defp git_clone_origin_arg(_args), do: nil

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
