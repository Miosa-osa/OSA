defmodule OptimalSystemAgent.CLI.Headless do
  @moduledoc """
  `osa run`: OSA as a headless agent, the equivalent of `claude -p` and
  `codex exec`.

      osa run "fix the failing test"
      echo "fix the failing test" | osa run --format stream-json --overdrive
      osa run --resume <id> --format stream-json < next_message.txt
      osa run --input-format stream-json --format stream-json   # one process, many turns

  It runs the SAME session engine the TUI drives (`Runtime.SessionManager` and
  `Agent.Loop`: context assembly, auto-compaction, persistence to
  `$OSA_HOME/sessions/<id>.json`), so a session started headless can be resumed
  headless or in the TUI and vice versa. What it never touches is the terminal:
  no TUI, no setup wizard, no prompt on stdin, no raw mode, and it binds no port
  and starts no channel (see `RunProfile`), so it can run beside a daemon.

  ## Exit codes

    * `0`  the run finished and every turn succeeded
    * `1`  a turn failed (provider error, the agent loop returned an error)
    * `2`  usage error (unknown flag, empty prompt, bad session id, bad MCP config)
    * `3`  OSA could not start
    * `79` `--resume` / `--continue` found no session to continue (the same
           code MIOSA's runner uses for `HARNESS_SESSION_MISSING`)

  The event schema is documented on `CLI.Headless.Stream` and in
  `docs/headless.md`; the approval hook on `Agent.Hooks.ApprovalHook`.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{PermissionMode, SessionId, SessionPersistence, ToolStream}
  alias OptimalSystemAgent.Agent.Hooks.ApprovalHook
  alias OptimalSystemAgent.CLI.Headless.{Options, Stream}
  alias OptimalSystemAgent.CLI.Sanitize
  alias OptimalSystemAgent.Runtime.SessionManager

  @exit_ok 0
  @exit_failed 1
  @exit_usage 2
  @exit_boot 3
  @exit_session_missing 79

  @app :optimal_system_agent
  @mcp_wait_default_ms 30_000
  @default_tool_await_ms 1_200_000

  @type io :: %{out: IO.device(), err: IO.device(), stdin: IO.device()}

  @doc "Exit code for a `--resume`/`--continue` with no session to continue."
  @spec session_missing_exit() :: 79
  def session_missing_exit, do: @exit_session_missing

  @doc """
  Entry point for the release (`osagent run ...`) and `mix osa.run`. Sets up
  the process (logs to stderr, the event stream on `OSA_EVENT_FD` when the
  launcher provides one), runs, and halts with the exit code.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    io = %{out: event_device(), err: :standard_error, stdin: :stdio}
    log_to_stderr(argv)
    code = run(argv, io)
    System.halt(code)
  end

  @doc "Run `osa run` with `argv` against `io`. Returns the exit code."
  @spec run([String.t()], io()) :: non_neg_integer()
  def run(argv, io) do
    case Options.parse(argv) do
      {:error, message} ->
        say(io, "osa run: #{message}")
        @exit_usage

      {:ok, %Options{help: true}} ->
        IO.write(io.out, usage())
        @exit_ok

      {:ok, opts} ->
        execute(opts, io)
    end
  end

  # ── Run ──────────────────────────────────────────────────────────────

  defp execute(opts, io) do
    with {:ok, cwd} <- prepare_cwd(opts),
         {:ok, prompts} <- first_prompt(opts, io),
         :ok <- prepare_environment(opts),
         :ok <- boot(),
         :ok <- ready_hooks(),
         :ok <- wait_for_mcp(),
         :ok <- apply_effort(opts.effort),
         {:ok, provider} <- provider_atom(opts.provider),
         {:ok, session} <- resolve_session(opts, cwd) do
      session = Map.put(session, :provider, provider)
      adopt_working_dir(session.working_dir, cwd)
      run_session(opts, session, prompts, io)
    else
      {:usage, message} ->
        say(io, "osa run: #{message}")
        @exit_usage

      {:boot, message} ->
        say(io, "osa run: OSA could not start: #{message}")
        @exit_boot

      {:missing, message} ->
        say(io, "HARNESS_SESSION_MISSING: #{message}")
        @exit_session_missing
    end
  end

  defp run_session(opts, session, prompts, io) do
    sid = session.id

    configure_permissions(opts, sid)
    extend_tool_wait_for_approval_hook()

    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")
    :ok = Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, ToolStream.topic(sid))

    case SessionManager.ensure_loop(sid, loop_opts(opts, session)) do
      :ok ->
        emit(io, opts, init_event(opts, session))
        code = turns(opts, sid, prompts, io)
        _ = SessionPersistence.flush_sync(sid)
        _ = remember_model(sid)
        code

      {:error, reason} ->
        say(io, "osa run: could not start the agent session: #{inspect(reason)}")
        @exit_boot
    end
  end

  defp loop_opts(opts, session) do
    [
      channel: :headless,
      user_id: "headless",
      working_dir: session.working_dir,
      provider: session.provider,
      model: opts.model || resumed_model(session),
      max_budget_usd: opts.max_budget_usd,
      permission_mode: opts.permission_mode,
      system_prompt_override: opts.system_prompt,
      system_prompt_append: opts.append_system_prompt,
      allowed_tools: opts.tools,
      blocked_tools: blocked_tools(opts.disallowed_rules),
      ask_user: opts.ask_user
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # A resumed conversation stays on the model it ran on, unless this run names
  # one or now resolves to a different provider (a model id means nothing to
  # another provider).
  defp resumed_model(%{resumed: true, id: sid} = session) do
    provider =
      to_string(
        session.provider || OptimalSystemAgent.Providers.Registry.resolved_default_provider()
      )

    case SessionPersistence.last_model(sid) do
      {^provider, model} -> model
      _ -> nil
    end
  end

  defp resumed_model(_session), do: nil

  defp remember_model(sid) do
    case loop_snapshot(sid) do
      %{provider: provider, model: model} when not is_nil(provider) and is_binary(model) ->
        SessionPersistence.update_metadata(sid, %{provider: to_string(provider), model: model})

      _ ->
        :ok
    end
  end

  # ── Turns ────────────────────────────────────────────────────────────

  defp turns(%Options{input_format: "stream-json"} = opts, sid, [], io) do
    stream_turns(opts, sid, io, @exit_ok)
  end

  defp turns(opts, sid, [prompt], io) do
    case turn(opts, sid, prompt, io) do
      :ok -> @exit_ok
      :error -> @exit_failed
    end
  end

  # One process, many turns: a user message per stdin line, a `result` per
  # turn, until stdin closes. The exit code is 1 when any turn failed.
  defp stream_turns(opts, sid, io, code) do
    case IO.gets(io.stdin, "") do
      line when is_binary(line) ->
        case input_message(line) do
          :skip ->
            stream_turns(opts, sid, io, code)

          {:ok, text} ->
            result = turn(opts, sid, text, io)
            stream_turns(opts, sid, io, if(result == :error, do: @exit_failed, else: code))

          {:error, message} ->
            emit(io, opts, %{
              type: "system",
              subtype: "input_error",
              error: message,
              session_id: sid
            })

            stream_turns(opts, sid, io, code)
        end

      _eof ->
        code
    end
  end

  @doc """
  One `--input-format stream-json` line as a user message. Claude Code's shape,
  `{"type":"user","message":{"role":"user","content":"..." | [blocks]}}`;
  `{"type":"user","content":"..."}` and `{"prompt":"..."}` are accepted too.
  """
  @spec input_message(String.t()) :: {:ok, String.t()} | :skip | {:error, String.t()}
  def input_message(line) do
    case String.trim(line) do
      "" ->
        :skip

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{"type" => "user", "message" => %{"content" => content}}} -> text_of(content)
          {:ok, %{"type" => "user", "content" => content}} -> text_of(content)
          {:ok, %{"prompt" => content}} -> text_of(content)
          {:ok, %{"type" => type}} -> {:error, "unsupported input message type #{inspect(type)}"}
          {:ok, _} -> {:error, "input line is not a user message"}
          {:error, _} -> {:error, "input line is not valid JSON"}
        end
    end
  end

  defp text_of(content) when is_binary(content) do
    if String.trim(content) == "", do: {:error, "empty user message"}, else: {:ok, content}
  end

  defp text_of(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      text when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
    |> text_of()
  end

  defp text_of(_), do: {:error, "user message content must be text"}

  # One turn: send the message, stream every event until the loop answers,
  # then the `result`. Returns `:ok` or `:error`.
  defp turn(opts, sid, prompt, io) do
    before = spend_snapshot(sid)
    started = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
        # `--max-turns` is Claude Code's: a cap on the agent's model round-trips
        # in this turn, which is OSA's per-turn `max_iterations`.
        turn_opts = if opts.max_turns, do: [max_iterations: opts.max_turns], else: []
        SessionManager.process_message(sid, prompt, turn_opts)
      end)

    {outcome, stream} = collect(opts, io, task, Stream.new(sid))
    {outcome, stream} = drain(opts, io, outcome, stream)

    {status, text, error} =
      case outcome do
        {:ok, response} when is_map(stream.turn_error) ->
          {:error, to_string(response), turn_error_text(stream.turn_error)}

        {:ok, response} ->
          {:ok, to_string(response), nil}

        {:plan, plan} ->
          {:ok, to_string(plan), nil}

        {:error, reason} ->
          {:error, describe(reason), describe(reason)}

        other ->
          {:error, "unexpected agent reply: #{inspect(other, limit: 5)}", "unexpected reply"}
      end

    # On failure, text streamed before the error is still flushed as an
    # `assistant` message, but the error text is not presented as an answer.
    {final_events, stream} = Stream.finish(stream, if(status == :ok, do: text))

    Enum.each(final_events, &emit(io, opts, &1))

    result = result_event(sid, status, text, error, before, started, stream)
    finish_output(opts, io, status, text, result)
    write_last_message(opts.output_last_message, status, text, io)
    status
  end

  # Receive session events while the turn runs. The turn task replies after
  # every event it caused was broadcast, and on one node a message sent before
  # another is enqueued before it, so the reply is the last thing to arrive.
  defp collect(opts, io, %Task{ref: ref} = task, stream) do
    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        {reply, stream}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {{:error, "the agent turn crashed: #{inspect(reason, limit: 5)}"}, stream}

      {:osa_event, _} = message ->
        collect(opts, io, task, step(opts, io, stream, message))

      {:osa_tool_stream, _, _} = message ->
        collect(opts, io, task, step(opts, io, stream, message))
    end
  end

  # Anything already in the mailbox when the reply arrived.
  defp drain(opts, io, outcome, stream) do
    receive do
      {:osa_event, _} = message ->
        drain(opts, io, outcome, step(opts, io, stream, message))

      {:osa_tool_stream, _, _} = message ->
        drain(opts, io, outcome, step(opts, io, stream, message))
    after
      0 -> {outcome, stream}
    end
  end

  defp step(opts, io, stream, message) do
    {events, stream} = Stream.handle(stream, message)
    Enum.each(events, &emit(io, opts, &1))
    stream
  end

  defp result_event(sid, status, text, error, before, started, stream) do
    after_spend = spend_snapshot(sid)
    state = loop_snapshot(sid)

    base = %{
      type: "result",
      subtype: if(status == :ok, do: "success", else: "error_during_execution"),
      is_error: status != :ok,
      result: text,
      # `content` is the field name of OSA's earlier headless stream; kept so
      # consumers written against it keep reading the final answer.
      content: text,
      session_id: sid,
      duration_ms: System.monotonic_time(:millisecond) - started,
      num_turns: Map.get(state, :iteration),
      model: to_string_or_nil(Map.get(state, :model)),
      provider: to_string_or_nil(Map.get(state, :provider)),
      total_cost_usd: delta(after_spend, before, :cost_usd),
      usage: %{
        input_tokens: delta(after_spend, before, :input_tokens),
        output_tokens: delta(after_spend, before, :output_tokens),
        cache_creation_tokens: delta(after_spend, before, :cache_creation_tokens),
        cache_read_tokens: delta(after_spend, before, :cache_read_tokens)
      },
      session_cost_usd: Map.get(after_spend, :cost_usd),
      tree_cost_usd: Map.get(after_spend, :tree_cost_usd),
      session_usage: %{
        input_tokens: Map.get(after_spend, :input_tokens),
        output_tokens: Map.get(after_spend, :output_tokens),
        cache_creation_tokens: Map.get(after_spend, :cache_creation_tokens),
        cache_read_tokens: Map.get(after_spend, :cache_read_tokens)
      },
      usage_complete: after_spend != %{},
      context: context_usage(sid, state, stream.context),
      compactions: stream.compactions
    }

    if error, do: Map.put(base, :error, error), else: base
  end

  defp finish_output(%Options{format: "text"}, io, :ok, text, _result) do
    IO.write(io.out, text_output(text) <> "\n")
  end

  defp finish_output(%Options{format: "text"}, io, :error, text, _result) do
    say(io, "Error: " <> Sanitize.scrub_line(text))
  end

  defp finish_output(opts, io, _status, _text, result), do: emit_line(io, opts, result, :always)

  # Codex's `--output-last-message`: the final answer of the latest successful
  # turn, written to a file (overwritten per turn).
  defp write_last_message(nil, _status, _text, _io), do: :ok
  defp write_last_message(_path, :error, _text, _io), do: :ok

  defp write_last_message(path, :ok, text, io) do
    case File.write(Path.expand(path), text) do
      :ok ->
        :ok

      {:error, reason} ->
        say(io, "osa run: could not write #{path}: #{:file.format_error(reason)}")
    end
  end

  # ── Output ───────────────────────────────────────────────────────────

  # stream-json: every event. json: only the final result object. text: the
  # answer only; with --verbose, tool activity on stderr.
  defp emit(io, %Options{format: "stream-json"}, event), do: write_json(io, event)

  defp emit(io, %Options{format: "text", verbose: true}, %{type: "tool_use"} = event),
    do: say(io, "-> #{event.name} #{Sanitize.scrub_line(inspect_input(event.input))}")

  defp emit(io, %Options{format: "text", verbose: true}, %{type: "tool_result"} = event),
    do: say(io, "<- #{event.name}#{if event.is_error, do: " (error)", else: ""}")

  defp emit(_io, _opts, _event), do: :ok

  defp emit_line(io, %Options{format: format}, event, :always)
       when format in ["json", "stream-json"],
       do: write_json(io, event)

  defp write_json(io, event), do: IO.binwrite(io.out, json_line(event) <> "\n")

  defp say(io, message), do: IO.puts(io.err, message)

  defp inspect_input(input) when is_map(input) do
    input |> Jason.encode!() |> String.slice(0, 160)
  rescue
    _ -> ""
  end

  defp inspect_input(_), do: ""

  @doc """
  The bytes the `text` format puts on stdout: a terminal render, so scrubbed
  of control sequences (`CLI.Sanitize`, block tier).
  """
  @spec text_output(term()) :: String.t()
  def text_output(response), do: response |> to_string() |> Sanitize.scrub_block()

  @doc """
  One NDJSON line. `escape: :unicode_safe` keeps the line inert on a terminal
  (C1 controls are escaped too) while decoding to exactly the original string,
  so machine-readable output is lossless and never scrubbed.
  """
  @spec json_line(map()) :: String.t()
  def json_line(map), do: Jason.encode!(ordered(map), escape: :unicode_safe)

  # `type`, `subtype` and `session_id` lead every event, the rest in key order,
  # so a line reads the same way every time (a map has no order of its own).
  @lead_keys [:type, :subtype, :session_id]

  defp ordered(%{} = map) when not is_struct(map) do
    lead = for key <- @lead_keys, Map.has_key?(map, key), do: {key, Map.fetch!(map, key)}

    rest =
      map
      |> Map.drop(@lead_keys)
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)

    Jason.OrderedObject.new(lead ++ rest)
  end

  defp ordered(other), do: other

  # ── Init ─────────────────────────────────────────────────────────────

  defp init_event(opts, session) do
    state = loop_struct(session.id)

    %{
      type: "system",
      subtype: "init",
      session_id: session.id,
      cwd: session.working_dir,
      model: to_string_or_nil(Map.get(state, :model) || opts.model),
      provider: to_string_or_nil(Map.get(state, :provider)),
      permission_mode: permission_label(state),
      tools: state |> Map.get(:tools, []) |> List.wrap() |> Enum.map(&tool_name/1),
      mcp_servers: mcp_servers(),
      resumed: session.resumed,
      history_messages: state |> Map.get(:messages, []) |> List.wrap() |> length(),
      osa_version: version()
    }
  end

  defp permission_label(state) do
    OptimalSystemAgent.Agent.Loop.ToolExecutor.hook_permission_mode(state)
  rescue
    _ -> "default"
  end

  defp tool_name(%{name: name}), do: to_string(name)
  defp tool_name(%{"name" => name}), do: to_string(name)
  defp tool_name(_), do: ""

  defp mcp_servers do
    OptimalSystemAgent.MCP.Client.Manager.list_servers()
    |> Enum.map(&%{name: &1.name, status: to_string(&1.status)})
  rescue
    _ -> []
  end

  defp version do
    case Application.spec(@app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  # ── Setup ────────────────────────────────────────────────────────────

  # The workspace: `--cwd`, else the directory the launcher was started in
  # (`OSA_ORIGINAL_CWD`, because the source launcher runs `mix` from the OSA
  # checkout), else the process cwd. Exported so boot captures the same one.
  defp prepare_cwd(opts) do
    dir =
      cond do
        is_binary(opts.cwd) -> Path.expand(opts.cwd)
        (env = System.get_env("OSA_ORIGINAL_CWD")) not in [nil, ""] and File.dir?(env) -> env
        true -> File.cwd!()
      end

    if File.dir?(dir) do
      File.cd!(dir)
      System.put_env("OSA_ORIGINAL_CWD", dir)
      {:ok, dir}
    else
      {:usage, "--cwd #{dir} is not a directory"}
    end
  end

  # The prompt for a text-input run, from the arguments or stdin. Read before
  # boot so an empty prompt fails without starting anything.
  defp first_prompt(%Options{input_format: "stream-json"}, _io), do: {:ok, []}

  defp first_prompt(%Options{prompt: prompt}, io) do
    text =
      case prompt do
        p when is_binary(p) and p != "" -> p
        _ -> read_all(io.stdin)
      end

    if is_binary(text) and String.trim(text) != "" do
      {:ok, [text]}
    else
      {:usage,
       "no prompt: pass it as an argument or on stdin (osa run \"...\" or osa run < task.txt)"}
    end
  end

  defp read_all(device) do
    case IO.read(device, :eof) do
      data when is_binary(data) -> String.trim(data)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp prepare_environment(opts) do
    if opts.settings, do: System.put_env("OSA_SETTINGS", Path.expand(opts.settings))

    with :ok <- validate_mcp_configs(opts.mcp_configs) do
      OptimalSystemAgent.RunProfile.put(:headless)
      Application.put_env(@app, :mcp_flag_configs, opts.mcp_configs)
      Application.put_env(@app, :mcp_strict, opts.strict_mcp_config)
      :ok
    end
  end

  defp validate_mcp_configs(configs) do
    Enum.reduce_while(configs, :ok, fn spec, :ok ->
      case OptimalSystemAgent.MCP.Config.parse_flag_config(spec) do
        {:ok, _} -> {:cont, :ok}
        {:error, message} -> {:halt, {:usage, message}}
      end
    end)
  end

  defp boot do
    case Application.ensure_all_started(@app) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> {:boot, "#{inspect(app)}: #{inspect(reason, limit: 8)}"}
      {:error, reason} -> {:boot, inspect(reason, limit: 8)}
    end
  end

  # Every hook must be in place before the first tool call. The approval hook
  # registers synchronously; settings hooks are registered by
  # `Channels.Starter` in a `handle_continue`, which a `:sys` call waits out,
  # and then a call to `Agent.Hooks` drains its registration casts.
  defp ready_hooks do
    ApprovalHook.register_from_env()

    for name <- [OptimalSystemAgent.Channels.Starter, OptimalSystemAgent.Agent.Hooks] do
      try do
        :sys.get_state(name, 10_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # MCP servers connect asynchronously; their tools must be registered before
  # the session's tool list is built, or the first turn runs without them.
  # Bounded by OSA_MCP_STARTUP_TIMEOUT_MS (default 30s): a server still
  # connecting then is reported in `init` as such and the run goes on.
  #
  # Each server gets ONE attempt. A server seen in any state other than
  # `:connecting` (ready, failed, dormant) is not waited on again, so a server
  # that crashes on startup and retries in the background does not hold the
  # run for its whole backoff. MEASURED: a stdio server failing on an
  # ImportError added the full 30s to every `osa run` (34.3s total against
  # 4.4s with `--strict-mcp-config`).
  defp wait_for_mcp do
    deadline = System.monotonic_time(:millisecond) + mcp_wait_ms()
    wait_for_mcp(deadline, MapSet.new())
  end

  defp wait_for_mcp(deadline, settled) do
    servers = mcp_status_list()

    settled =
      servers
      |> Enum.reject(&connecting?/1)
      |> Enum.reduce(settled, &MapSet.put(&2, &1.name))

    waiting? = Enum.any?(servers, &(connecting?(&1) and not MapSet.member?(settled, &1.name)))

    cond do
      not waiting? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(100)
        wait_for_mcp(deadline, settled)
    end
  end

  defp connecting?(%{status: status}), do: status in [:connecting, "connecting"]
  defp connecting?(_), do: false

  defp mcp_status_list do
    OptimalSystemAgent.MCP.Client.Manager.list_servers()
  rescue
    _ -> []
  end

  defp mcp_wait_ms do
    case Integer.parse(System.get_env("OSA_MCP_STARTUP_TIMEOUT_MS") || "") do
      {ms, ""} when ms >= 0 -> ms
      _ -> @mcp_wait_default_ms
    end
  end

  defp apply_effort(nil), do: :ok

  defp apply_effort(effort) do
    case OptimalSystemAgent.Agent.Effort.set(effort) do
      :ok ->
        :ok

      {:error, :invalid_level} ->
        {:usage,
         "unknown --effort #{inspect(effort)}. Valid levels: fast, medium, high, xhigh, ultra " <>
           "(legacy aliases: low, max)."}
    end
  end

  defp provider_atom(nil), do: {:ok, nil}

  defp provider_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:usage, "unknown --provider #{inspect(name)}"}
  end

  @doc """
  Which session this run continues, and in which directory.

    * `--resume <id>`: that session; it must have a transcript on disk.
    * `--continue`: the newest session saved for `cwd`.
    * `--session-id <id>`: a NEW session with that id; it must not exist.
    * otherwise a new session with a generated id.

  A resumed session runs in the directory it was saved with (when it still
  exists and `--cwd` was not given), so the conversation keeps its workspace.
  """
  @spec resolve_session(Options.t(), String.t()) ::
          {:ok, %{id: String.t(), resumed: boolean(), working_dir: String.t()}}
          | {:missing, String.t()}
          | {:usage, String.t()}
  def resolve_session(%Options{resume: id} = opts, cwd) when is_binary(id) do
    if SessionPersistence.transcript_exists?(id) do
      {:ok, %{id: id, resumed: true, working_dir: resumed_dir(opts, id, cwd)}}
    else
      {:missing, "osa session #{id} is not on this machine (looked in #{sessions_dir()})"}
    end
  end

  def resolve_session(%Options{continue: true} = opts, cwd) do
    case SessionPersistence.find_latest_for_dir(cwd) do
      id when is_binary(id) ->
        {:ok, %{id: id, resumed: true, working_dir: resumed_dir(opts, id, cwd)}}

      _ ->
        {:missing, "no osa session to continue in #{cwd}"}
    end
  end

  def resolve_session(%Options{session_id: id}, cwd) when is_binary(id) do
    if SessionPersistence.exists?(id) do
      {:usage, "session #{id} already exists; continue it with --resume #{id}"}
    else
      {:ok, %{id: id, resumed: false, working_dir: cwd}}
    end
  end

  def resolve_session(_opts, cwd) do
    {:ok, %{id: SessionId.generate("headless"), resumed: false, working_dir: cwd}}
  end

  defp resumed_dir(%Options{cwd: explicit}, _id, cwd) when is_binary(explicit), do: cwd

  defp resumed_dir(_opts, id, cwd) do
    case SessionPersistence.working_dir_of(id) do
      dir when is_binary(dir) ->
        if File.dir?(dir), do: dir, else: cwd

      _ ->
        cwd
    end
  end

  # A resumed session runs where it was saved: make that the process cwd and
  # the boot-captured workspace too, so every cwd resolution agrees.
  defp adopt_working_dir(dir, dir), do: :ok

  defp adopt_working_dir(dir, _cwd) do
    File.cd!(dir)
    System.put_env("OSA_ORIGINAL_CWD", dir)
    OptimalSystemAgent.Workspace.Cwd.set_original_cwd(dir)
    :ok
  end

  defp sessions_dir, do: Path.join(OptimalSystemAgent.ConfigFile.config_dir(), "sessions")

  # Each run states its own mode. The sticky per-session store would otherwise
  # carry an earlier run's `--overdrive` into a resumed run that did not ask for
  # it (and `approve_tool_call/2` reads the store first).
  defp configure_permissions(opts, sid) do
    case opts.permission_mode do
      nil -> PermissionMode.clear(sid)
      mode -> PermissionMode.put(sid, mode)
    end

    Enum.each(opts.add_dirs, &OptimalSystemAgent.Permissions.add_directory(Path.expand(&1)))

    rules =
      %{"allow" => opts.allowed_rules, "deny" => opts.disallowed_rules}
      |> Enum.reject(fn {_k, v} -> v == [] end)
      |> Map.new()

    # A headless process runs exactly one session, so the daemon-wide session
    # layer is this run's layer.
    if rules != %{} do
      OptimalSystemAgent.Settings.set_session_for(nil, "permissions", rules)
    end

    :ok
  end

  # A bare tool name in --disallowed-tools also removes the tool from what the
  # model is offered (Claude Code parity); a rule with content only denies.
  defp blocked_tools(rules) do
    case Enum.reject(rules, &String.contains?(&1, "(")) do
      [] -> nil
      names -> Enum.map(names, &OptimalSystemAgent.Permissions.canonical_tool_name/1)
    end
  end

  # A person may take longer than the 20-minute tool backstop to answer an
  # approval request. With an approval hook, the backstop is the hook's own
  # timeout plus the default.
  defp extend_tool_wait_for_approval_hook do
    case ApprovalHook.config() do
      %{timeout_ms: hook_ms} ->
        current = Application.get_env(@app, :tool_await_timeout_ms, @default_tool_await_ms)
        wanted = hook_ms + @default_tool_await_ms

        if is_integer(current) and current < wanted do
          Application.put_env(@app, :tool_await_timeout_ms, wanted)
        end

      nil ->
        :ok
    end
  end

  # ── State reads ──────────────────────────────────────────────────────

  defp loop_struct(sid) do
    case SessionManager.lookup_loop(sid) do
      {:ok, pid, _owner} -> :sys.get_state(pid, 10_000) |> Map.from_struct()
      :error -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp loop_snapshot(sid) do
    case OptimalSystemAgent.Agent.Loop.get_state(sid) do
      {:ok, %{} = snap} -> snap
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp spend_snapshot(sid) do
    case loop_snapshot(sid) do
      %{spend: %{} = spend} -> spend
      _ -> %{}
    end
  end

  defp delta(after_spend, before, key) do
    a = Map.get(after_spend, key)
    b = Map.get(before, key, 0)

    cond do
      is_float(a) and is_number(b) -> Float.round(a - b, 6)
      is_integer(a) and is_integer(b) -> a - b
      true -> nil
    end
  end

  # Tokens in use against the model's window, where auto-compaction fires, as
  # the TUI's context meter shows them (`/context`).
  defp context_usage(sid, state, from_stream) do
    model = Map.get(state, :model)

    case SessionManager.context_budget(sid) do
      {:ok, %{max_tokens: window, occupied_tokens: used} = budget}
      when is_integer(window) and window > 0 ->
        %{
          used_tokens: used,
          window_tokens: window,
          percent: Map.get(budget, :utilization_pct) || Stream.percent(used, window),
          compact_at_tokens: compact_at(window, model, from_stream)
        }

      _ ->
        from_stream
    end
  rescue
    _ -> from_stream
  catch
    :exit, _ -> from_stream
  end

  defp compact_at(window, model, from_stream) do
    case from_stream && from_stream[:compact_at_tokens] do
      n when is_integer(n) and n > 0 -> n
      _ -> OptimalSystemAgent.Agent.Loop.CompactionThresholds.compact_at(window, model)
    end
  end

  # ── Process setup (main/1 only) ──────────────────────────────────────

  # The launchers run `exec 3>&1 1>&2` and set OSA_EVENT_FD=3: the event stream
  # gets the real stdout to itself and anything else the VM prints lands on
  # stderr. Without a launcher, plain stdout.
  defp event_device do
    with fd when is_binary(fd) <- System.get_env("OSA_EVENT_FD"),
         {n, ""} when n > 2 <- Integer.parse(fd),
         {:ok, device} <- File.open("/dev/fd/#{n}", [:append, :binary]) do
      device
    else
      _ -> :stdio
    end
  end

  # Logs go to stderr (never into the event stream), at :error by default,
  # :info with --verbose, off with --quiet.
  defp log_to_stderr(argv) do
    level =
      cond do
        "--quiet" in argv or "-q" in argv -> :none
        "--verbose" in argv -> :info
        true -> :error
      end

    Logger.configure(level: level)

    with {:ok, config} <- :logger.get_handler_config(:default),
         :ok <- :logger.remove_handler(:default) do
      handler_config = Map.get(config, :config, %{}) |> Map.put(:type, :standard_error)

      :logger.add_handler(
        :default,
        Map.get(config, :module, :logger_std_h),
        config |> Map.drop([:id, :module]) |> Map.put(:config, handler_config)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp turn_error_text(%{} = error) do
    reason = error[:reason] || error["reason"] || "the model provider failed"
    owner = error[:owner] || error["owner"]
    if owner, do: "#{reason} (fault: #{owner})", else: to_string(reason)
  end

  defp describe(reason) when is_binary(reason), do: reason

  defp describe(reason) when is_atom(reason),
    do: reason |> to_string() |> String.replace("_", " ")

  defp describe(reason), do: inspect(reason, limit: 8)

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  @doc "Usage text for `osa run --help`."
  @spec usage() :: String.t()
  def usage do
    """
    osa run - run the OSA agent headless (no TUI, no prompts).

    Usage:
      osa run [options] [prompt]          prompt as arguments, or on stdin
      osa run --input-format stream-json --format stream-json
                                          one process, one user message per stdin line

    Output:
      -f, --format text|json|stream-json  text (default): the answer; json: one result
                                          object; stream-json: NDJSON events
          --input-format text|stream-json
          --verbose / -q, --quiet         more / no diagnostics on stderr

    Session:
      -r, --resume <id>                   continue a saved session (exit 79 if missing)
      -c, --continue                      continue the newest session in this directory
          --session-id <id>               start a new session with this id

    Agent:
      -m, --model <model>                 model for this run (provider from env/config)
          --provider <name>               provider override
          --overdrive                     full auto: no approval prompts
                                          (also --dangerously-skip-permissions, --yolo)
          --permission-mode <mode>        ask | auto-edit | plan | overdrive
          --max-turns <n>                 cap on the agent's model round-trips per turn
          --max-budget <usd>              spend cap for the session
          --effort <level>                fast | medium | high | xhigh | ultra
          --append-system-prompt <text>   (or --append-system-prompt-file <path>)
          --system-prompt <text>          replace the system prompt (or -file <path>)
          --tools <list>                  only these tools are offered
          --allowed-tools <rules>         allow without approval, e.g. "shell_execute(git:*)"
          --disallowed-tools <rules>      deny; a bare tool name is also removed
          --mcp-config <file|json>        extra MCP servers (repeatable)
          --strict-mcp-config             only the --mcp-config servers
          --settings <file>               extra settings file (OSA_SETTINGS)
          --add-dir <dir>                 also allow tools in this directory (repeatable)
      -o, --output-last-message <file>    write the final answer to a file
      -C, --cwd <dir>                     workspace directory (default: current)
          --ask-user                      allow the agent to stop and ask (off by default)

    Approval hook: OSA_PRE_TOOL_HOOK=<command> gets each tool call as Claude Code
    PreToolUse JSON on stdin; exit 0 allows, exit 2 denies (reason on stdout).

    Exit codes: 0 ok, 1 a turn failed, 2 usage, 3 could not start, 79 no session.
    """
  end
end
