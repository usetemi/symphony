defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Claude Code CLI adapter for Symphony.

  Replaces the Codex app-server JSON-RPC protocol with Claude Code's
  `--print --output-format stream-json` mode.

  Key differences from Codex adapter:
  - No persistent subprocess. Each turn launches a fresh `claude --print` process.
  - Multi-turn via `--resume <session-id>`, not JSON-RPC `turn/start` on a persistent thread.
  - No approval protocol. `--dangerously-skip-permissions` handles permissions.
  - No dynamic tools. Claude Code uses MCP tools configured in the repo's .claude/settings.json.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          turn_count: non_neg_integer()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    case validate_workspace_cwd(workspace, worker_host) do
      {:ok, expanded_workspace} ->
        session_id = generate_session_id()

        {:ok,
         %{
           session_id: session_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           turn_count: 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          session_id: session_id,
          workspace: workspace,
          worker_host: worker_host,
          turn_count: turn_count
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = "turn-#{turn_count + 1}"
    compound_session_id = "#{session_id}-#{turn_id}"

    Logger.info(
      "Claude session starting for #{issue_context(issue)} session_id=#{compound_session_id}"
    )

    emit_message(
      on_message,
      :session_started,
      %{session_id: compound_session_id, thread_id: session_id, turn_id: turn_id},
      %{}
    )

    case start_claude_process(workspace, worker_host, session_id, turn_count, prompt) do
      {:ok, port} ->
        metadata = port_metadata(port, worker_host)

        case await_turn_completion(port, on_message, metadata) do
          {:ok, result} ->
            Logger.info(
              "Claude session completed for #{issue_context(issue)} session_id=#{compound_session_id}"
            )

            {:ok,
             %{
               result: result,
               session_id: compound_session_id,
               thread_id: session_id,
               turn_id: turn_id,
               session: %{session | turn_count: turn_count + 1}
             }}

          {:error, reason} ->
            Logger.warning(
              "Claude session ended with error for #{issue_context(issue)} session_id=#{compound_session_id}: #{inspect(reason)}"
            )

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{session_id: compound_session_id, reason: reason},
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Claude session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session) do
    # No-op: Claude Code processes are ephemeral per-turn.
    # Each `run_turn` launches and awaits its own process.
    :ok
  end

  # --- Private: Process Launch ---

  defp start_claude_process(workspace, nil = _worker_host, session_id, turn_count, prompt) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      command = build_claude_command(session_id, turn_count)
      prompt_file = write_prompt_file(workspace, session_id, turn_count, prompt)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist("#{command} < #{shell_escape(prompt_file)}")],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_claude_process(workspace, worker_host, session_id, turn_count, prompt)
       when is_binary(worker_host) do
    command = build_claude_command(session_id, turn_count)
    prompt_file = write_prompt_file(workspace, session_id, turn_count, prompt)

    remote_command =
      "cd #{shell_escape(workspace)} && #{command} < #{shell_escape(prompt_file)}"

    SymphonyElixir.SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp build_claude_command(_session_id, turn_count) do
    base_command = Config.settings!().codex.command

    if turn_count == 0 do
      base_command
    else
      # Use --continue to resume the last conversation in the workspace directory.
      # This gives Claude full context from previous turns.
      base_command <> " --continue"
    end
  end

  defp write_prompt_file(workspace, session_id, turn_count, prompt) do
    dir = Path.join(workspace, ".symphony")
    File.mkdir_p!(dir)
    file = Path.join(dir, "prompt-#{session_id}-turn-#{turn_count + 1}.md")
    File.write!(file, prompt)
    file
  end

  # --- Private: Stream Processing ---

  defp await_turn_completion(port, on_message, metadata) do
    receive_loop(port, on_message, Config.settings!().codex.turn_timeout_ms, "", metadata)
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, metadata) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_stream_line(port, on_message, complete_line, timeout_ms, metadata)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          metadata
        )

      {^port, {:exit_status, 0}} ->
        {:ok, :turn_completed}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        stop_port(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_stream_line(port, on_message, data, timeout_ms, metadata) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"type" => "result"} = payload} ->
        # Result event is the final event in stream-json mode.
        result_metadata = maybe_set_usage(metadata, payload)
        log_result_event(payload)

        emit_message(
          on_message,
          :turn_completed,
          %{payload: payload, raw: payload_string},
          result_metadata
        )

        # Don't return yet -- wait for process exit
        receive_loop(port, on_message, timeout_ms, "", result_metadata)

      {:ok, %{"type" => "assistant", "message" => message} = payload} ->
        Logger.info("Claude: assistant message (#{truncate_message(message)})")

        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: truncate(payload_string), message: truncate_message(message)},
          maybe_set_usage(metadata, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "tool_use", "tool" => %{"name" => tool_name}} = payload} ->
        Logger.info("Claude: tool_use #{tool_name}")

        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: truncate(payload_string)},
          maybe_set_usage(metadata, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "tool_use"} = payload} ->
        Logger.info("Claude: tool_use")

        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: truncate(payload_string)},
          maybe_set_usage(metadata, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "tool_result"} = payload} ->
        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: truncate(payload_string)},
          maybe_set_usage(metadata, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, %{"type" => "error"} = payload} ->
        Logger.warning("Claude: error event: #{truncate(payload_string)}")

        emit_message(
          on_message,
          :turn_failed,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_failed, payload}}

      {:ok, %{"type" => type} = payload} ->
        Logger.debug("Claude: event type=#{type}")

        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: truncate(payload_string)},
          maybe_set_usage(metadata, payload)
        )

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{payload: payload, raw: truncate(payload_string)},
          metadata
        )

        receive_loop(port, on_message, timeout_ms, "", metadata)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string)
        receive_loop(port, on_message, timeout_ms, "", metadata)
    end
  end

  # --- Private: Workspace Validation ---

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error,
           {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error,
           {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  # --- Private: Utilities ---

  defp generate_session_id do
    # Generate a UUID v4 without external dependencies.
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base, :worker_host, host)
      _ -> base
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp truncate(string) when byte_size(string) > @max_stream_log_bytes do
    String.slice(string, 0, @max_stream_log_bytes) <> "..."
  end

  defp truncate(string), do: string

  defp truncate_message(message) when is_map(message) do
    case Map.get(message, "content") do
      content when is_binary(content) -> truncate(content)
      _ -> inspect(message) |> truncate()
    end
  end

  defp truncate_message(message) when is_binary(message), do: truncate(message)
  defp truncate_message(message), do: inspect(message) |> truncate()

  defp log_non_json_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{text}")
      else
        Logger.debug("Claude stream output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp log_result_event(payload) do
    usage = Map.get(payload, "usage", %{})
    input = Map.get(usage, "input_tokens", 0)
    output = Map.get(usage, "output_tokens", 0)
    cost = Map.get(payload, "cost_usd")
    duration = Map.get(payload, "duration_ms")

    cost_str = if is_number(cost), do: " cost=$#{Float.round(cost / 1, 4)}", else: ""
    duration_str = if is_integer(duration), do: " duration=#{div(duration, 1000)}s", else: ""

    Logger.info(
      "Claude: result in=#{input} out=#{output} total=#{input + output}#{cost_str}#{duration_str}"
    )
  end

  defp default_on_message(_message), do: :ok
end
