defmodule SymphonyElixir.SSH do
  @moduledoc false

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      {remote_platform, cmd_opts} = Keyword.pop(opts, :remote_platform, :posix)
      {input, cmd_opts} = Keyword.pop(cmd_opts, :input)
      {command, input} = maybe_wrap_windows_stdin_script(command, input, remote_platform)
      args = ssh_args(host, command, remote_platform)

      {:ok, run_ssh_command(executable, args, cmd_opts, input)}
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)
      remote_platform = Keyword.get(opts, :remote_platform, :posix)

      port_opts =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(ssh_args(host, command, remote_platform), &String.to_charlist/1)
        ]
        |> maybe_put_line_option(line_bytes)

      {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)}
    end
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  @spec remote_shell_command(String.t(), atom()) :: String.t()
  def remote_shell_command(command, :windows) when is_binary(command) do
    encoded =
      command
      |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
      |> Base.encode64()

    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " <> encoded
  end

  def remote_shell_command(command, :windows_cmd) when is_binary(command) do
    "cmd.exe /d /s /c \"" <> windows_cmd_c_argument(command) <> "\""
  end

  def remote_shell_command(command, _platform) when is_binary(command) do
    remote_shell_command(command)
  end

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp run_ssh_command(executable, args, cmd_opts, nil) do
    System.cmd(executable, args, cmd_opts)
  end

  defp run_ssh_command(executable, args, cmd_opts, input) when is_binary(input) do
    {stderr_to_stdout?, _cmd_opts} = Keyword.pop(cmd_opts, :stderr_to_stdout, false)

    port_opts =
      [
        :binary,
        :exit_status,
        args: Enum.map(args, &String.to_charlist/1)
      ]
      |> maybe_put_stderr_to_stdout(stderr_to_stdout?)

    port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_opts)
    true = Port.command(port, input)
    collect_port_output(port, [])
  end

  defp maybe_put_stderr_to_stdout(port_opts, true), do: [:stderr_to_stdout | port_opts]
  defp maybe_put_stderr_to_stdout(port_opts, _value), do: port_opts

  defp collect_port_output(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | acc])

      {^port, {:exit_status, status}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end

  defp maybe_wrap_windows_stdin_script(command, input, :windows) when is_binary(input) do
    {
      windows_stdin_script_runner(),
      Base.encode64(command) <> "\n" <> input
    }
  end

  defp maybe_wrap_windows_stdin_script(command, input, _remote_platform), do: {command, input}

  defp windows_stdin_script_runner do
    [
      "$ErrorActionPreference = 'Stop'",
      "$script64 = [Console]::In.ReadLine()",
      "if ([string]::IsNullOrWhiteSpace($script64)) { throw 'SCRIPT_NOT_FOUND' }",
      "$script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script64))",
      "$path = Join-Path $env:TEMP ('symphony-hook-' + [guid]::NewGuid().ToString() + '.ps1')",
      "try { Set-Content -LiteralPath $path -Value $script -NoNewline -Encoding UTF8; & $path } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }"
    ]
    |> Enum.join("; ")
  end

  defp ssh_args(host, command, remote_platform) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([destination, remote_shell_command(command, remote_platform)])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    # OpenSSH does not interpret bare "host:port" as "host + port"; it treats the
    # whole value as a hostname and leaves the port at 22. We split that shorthand
    # here so worker config can use "localhost:2222" without requiring ssh:// URIs.
    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    # IPv6 literals contain ":" already, so we only accept additional ":port"
    # parsing when the host is explicitly bracketed, e.g. "[::1]:2222".
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end

  defp windows_cmd_c_argument(value) when is_binary(value) do
    String.replace(value, "\"", "^\"")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
