defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `shell_execute`.

  Mirrors the layout of `FileRead.Handler`:
    * `validate/2`            — type-checks input shape (cheap)
    * `check_permissions/2`   — command validation / security deny logic
    * `execute/2`             — actual shell execution

  All validation and execution logic was moved verbatim from the original
  `shell_execute.ex`. No semantic changes — just relocation and the
  validate/check_permissions/execute split.
  """

  require Logger

  alias OptimalSystemAgent.Agent.Safety.CommandVariants
  alias OptimalSystemAgent.Agent.Safety.DangerousCommands
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Constants
  alias OptimalSystemAgent.Tools.Builtins.ShellExecute.Parser
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Sandbox
  alias OptimalSystemAgent.Shell.BackgroundManager

  # ── Stage 1: Input validation ─────────────────────────────────────────
  #
  # This stage also normalises the command string (strip trailing &,
  # nohup prefix, leading/trailing whitespace) so that check_permissions
  # and execute always receive the clean, trimmed value. Normalisation is
  # cheap and idempotent — safe to do here.

  @spec validate(map(), UseContext.t()) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"command" => command} = input, _ctx) when is_binary(command) do
    raw = String.trim(command)

    cond do
      raw == "" ->
        # Return as a validation error so the adapter preserves the exact message
        # string (validation errors are stripped of code: {:error, msg, code} →
        # {:error, msg}), matching the original direct return of {:error, "Blocked: …"}.
        {:error, "Blocked: empty command", -32_602}

      # Reject an obviously incomplete command that ends with a dangling
      # trailing operator (`&&`, `||`, `|`, or a line-continuation `\`). Left
      # to run, such a command makes the shell wait for the missing right-hand
      # side and can hang until the wall-clock timeout — fail fast instead with
      # an actionable message so the model re-issues a complete command. A lone
      # trailing `&` is NOT rejected here: it is the background operator and is
      # stripped below to force foreground execution.
      dangling_operator?(raw) ->
        {:error,
         "Blocked: command ends with a dangling operator (&&, ||, |, or \\) — " <>
           "re-issue a complete command with a right-hand side.", -32_602}

      true ->
        # Strip trailing & (background operator) to force foreground execution.
        normalised = Regex.replace(~r/\s*&\s*$/, command, "")
        # Strip leading nohup.
        normalised = Regex.replace(~r/^\s*nohup\s+/, normalised, "")
        trimmed = String.trim(normalised)

        if trimmed == "" do
          {:error, "Blocked: empty command", -32_602}
        else
          {:ok, %{input | "command" => trimmed}}
        end
    end
  end

  def validate(%{"command" => _}, _ctx),
    do: {:error, "command must be a string", -32_602}

  def validate(_, _ctx),
    do: {:error, "Missing required parameter: command", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────
  #
  # At this point "command" is already normalised (stripped and trimmed)
  # by validate/2 above.

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()} | {:ask, String.t()}
  def check_permissions(%{"command" => command} = input, _ctx) do
    case classify_command(command) do
      :allow -> {:allow, input}
      {:ask, reason} -> {:ask, reason}
      {:deny, reason} -> {:deny, reason}
    end
  end

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"command" => command} = params, ctx) do
    # Default to the SESSION's real working directory (the user's project, via
    # the P0 cwd source of truth) — NOT ~/.osa/workspace. A coding agent has to
    # operate in the user's repo; caging it in an empty sandbox dir left it
    # unable to find or touch the project (CC runs in the real cwd + prompts).
    workspace =
      case OptimalSystemAgent.Workspace.Cwd.get() do
        dir when is_binary(dir) and dir != "" -> dir
        _ -> Path.expand("~/.osa/workspace") |> tap(&File.mkdir_p/1)
      end

    effective_cwd =
      case params["cwd"] do
        nil ->
          workspace

        "" ->
          workspace

        cwd_path ->
          expanded_cwd = Path.expand(cwd_path)
          if File.dir?(expanded_cwd), do: expanded_cwd, else: :invalid
      end

    cond do
      effective_cwd == :invalid ->
        {:error, "cwd does not exist: #{params["cwd"]}"}

      # BACKGROUND: spawn a supervised background process and return a
      # background_id immediately. The command still passed through the same
      # validate/check_permissions security pipeline above. Background exec
      # uses the host path only — sandbox routing is not supported here.
      truthy?(params["run_in_background"]) ->
        run_in_background(command, effective_cwd, ctx)

      true ->
        timeout = parse_timeout_ms(System.get_env("OSA_SHELL_TIMEOUT_MS"))

        # SANDBOX ROUTING: when a non-host sandbox backend is configured (or
        # sandbox mode is :required), route the command through Sandbox.Router
        # instead of raw host exec. Default config (no sandbox, :optional mode)
        # keeps the existing host execution path — no behavior change.
        if use_sandbox?() do
          run_in_sandbox(command, effective_cwd, timeout)
        else
          session_id = ctx && Map.get(ctx, :session_id)
          # Owning tool_call id — tags every live-output delta so a TUI can
          # route this command's stream to ITS OWN cell. Without it two
          # concurrent commands (or the SAME command run twice) share one
          # preview buffer and their output interleaves.
          tool_call_id = ctx && Map.get(ctx, :tool_use_id)
          run_command(command, effective_cwd, timeout, session_id, tool_call_id)
        end
    end
  end

  @registry OptimalSystemAgent.Shell.ForegroundRegistry

  @doc """
  Promote the foreground `shell_execute` command currently running for
  `session_id` to a supervised background task (TUI Ctrl+B mid-run detach).

  Looks up the process blocked in the foreground receive loop, signals it to
  hand its live OS process off to `BackgroundManager`, and waits briefly for the
  new `background_id`. Returns `{:error, :no_active_command}` when nothing is
  running for the session, or `{:error, :timeout}` if the command finished before
  the hand-off completed.
  """
  @spec detach_foreground(String.t()) ::
          {:ok, String.t()} | {:error, :no_active_command | :timeout | term()}
  def detach_foreground(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        ref = make_ref()
        send(pid, {:detach, self(), ref})

        receive do
          {:detached, ^ref, id} -> {:ok, id}
          {:detach_failed, ^ref, reason} -> {:error, reason}
        after
          3_000 -> {:error, :timeout}
        end

      [] ->
        {:error, :no_active_command}
    end
  end

  def detach_foreground(_), do: {:error, :no_active_command}

  # Resolve the command timeout from OSA_SHELL_TIMEOUT_MS. Pure + defensive so a
  # typo like "30s"/"5000ms"/"" falls back to the default instead of raising
  # ArgumentError before run_command's rescue (which would break EVERY shell call
  # until the env var is fixed). Public so it can be unit-tested without mutating
  # the process-global env (which flakes under parallel test runs).
  @doc false
  def parse_timeout_ms(nil), do: Constants.effective_timeout_ms()

  def parse_timeout_ms(s) when is_binary(s) do
    # Require the value to be a bare positive integer (milliseconds). A trailing
    # unit like "30s"/"5000ms" must fall back to the default rather than silently
    # parsing "30s" as 30ms — Integer.parse/1 returns {30, "s"}, so we insist the
    # remainder is empty.
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 ->
        n

      _ ->
        Logger.warning(
          "[shell_execute] invalid OSA_SHELL_TIMEOUT_MS=#{inspect(s)} — using default"
        )

        Constants.effective_timeout_ms()
    end
  end

  def parse_timeout_ms(_), do: Constants.effective_timeout_ms()

  # True when a trimmed command ends with an incomplete/dangling shell operator:
  #   * `&&` / `||`  — logical connective with no right-hand command
  #   * `|`          — pipe with no downstream command (a lone `|`, not `||`)
  #   * `\`          — a trailing line continuation
  # A single trailing `&` (background operator) is intentionally NOT matched:
  # it is handled by the background-strip in validate/2.
  defp dangling_operator?(cmd) when is_binary(cmd) do
    Regex.match?(~r/(?:&&|\|\|?|\\)\s*$/, cmd)
  end

  # Null device for redirecting a command's stdin so it can never block waiting
  # for interactive input (a key cause of silent multi-minute hangs).
  defp null_device do
    case :os.type() do
      {:win32, _} -> "NUL"
      _ -> "/dev/null"
    end
  end

  # Accept boolean true or the string "true" (some callers stringify args).
  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp run_in_background(command, cwd, ctx) do
    session_id = ctx && Map.get(ctx, :session_id)

    # Ensure a notifier is listening for this parent session BEFORE the worker
    # starts, so a fast command's completion broadcast is never missed (the
    # topic subscription must be live before the worker can exit). This reuses
    # the same re-entry mechanism the background-subagent path uses.
    if is_binary(session_id) do
      OptimalSystemAgent.Agent.BackgroundNotifier.ensure_started(session_id)
    end

    case BackgroundManager.start(command, cwd, session_id: session_id) do
      {:ok, id} ->
        # Announce the new background terminal so the TUI's live count updates.
        if is_binary(session_id) do
          Phoenix.PubSub.broadcast(
            OptimalSystemAgent.PubSub,
            "osa:session:#{session_id}",
            {:osa_event,
             %{
               type: :background_command_started,
               background_id: id,
               command: command,
               session_id: session_id,
               running_count: BackgroundManager.running_count()
             }}
          )
        end

        {:ok,
         "Started background command.\n" <>
           "- background_id: #{id}\n" <>
           "- cwd: #{cwd}\n\n" <>
           "The command is running in the background; you'll be notified automatically " <>
           "when it completes (with its exit code). You can also poll its output and status " <>
           "with the bash_output tool using background_id \"#{id}\". " <>
           "To stop it, call bash_output with kill=true."}

      {:error, reason} ->
        {:error, "Failed to start background command: #{reason}"}
    end
  end

  # Route to the sandbox only when the operator has actually configured one.
  # Host + :optional (the default) stays on the existing host path so nothing
  # changes unless a sandbox backend is selected.
  defp use_sandbox? do
    Sandbox.Router.required?() or Sandbox.Router.backend() != Sandbox.Host
  rescue
    _ -> false
  end

  defp run_in_sandbox(command, cwd, timeout_ms) do
    case Sandbox.Router.execute(command, working_dir: cwd, timeout: timeout_ms) do
      {:ok, output} -> {:ok, maybe_truncate(output)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, "Sandbox execution error: #{Exception.message(e)}"}
  end

  # ── Private: command classification (deny / ask / allow) ──────────────
  #
  # Claude-Code-aligned three-tier policy (see Constants moduledoc):
  #   catastrophic → :deny   (unrecoverable — hard block, never offered)
  #   risky        → :ask    (powerful but legitimate — inline permission prompt)
  #   safe         → :allow  (everything else — command substitution, /etc reads,
  #                           relative paths, `cd` anywhere, `env`, …)

  defp classify_command(command) do
    cond do
      # Catastrophic (built-in defaults + operator [permissions].catastrophic_patterns
      # + [permissions].deny) is checked FIRST — an operator `allow` can never
      # downgrade an unrecoverable operation.
      catastrophic?(command) or denied?(command) ->
        {:deny,
         "Blocked: refusing an unrecoverable operation (filesystem/disk destruction). " <>
           "If this is genuinely intended, run it yourself."}

      # Operator `[permissions].allow` — downgrade an otherwise-risky command to
      # :allow (but never a catastrophic/denied one, handled above). Checked
      # BEFORE the structured scan so an explicit operator allow is never
      # re-escalated by external-directory analysis.
      allowed?(command) ->
        :allow

      # ── Structured (opencode-style) analysis layer ──────────────────────
      # Tokenize the command, resolve its touched file paths, and compute the
      # arity prefix, THEN fold that into the three-tier decision:
      #   * risky command      → :ask, reason enriched with external dirs +
      #                          "always allow <prefix> *" hint
      #   * file mutation that  → :ask (external_directory), even if the base
      #     escapes the cwd       command would otherwise be safe
      #   * everything else     → :allow (unchanged)
      true ->
        scan = safe_scan(command)

        cond do
          risky?(command) ->
            {:ask, ask_reason(command, scan)}

          scan.external_dirs != [] ->
            {:ask, external_reason(scan)}

          true ->
            :allow
        end
    end
  end

  # Run the structured scan defensively — a malformed command must never crash
  # the permission gate. On any failure fall back to an empty scan (which leaves
  # the base three-tier decision untouched).
  defp safe_scan(command) do
    Parser.scan(command, current_cwd())
  rescue
    _ -> %{segments: [], external_dirs: [], always: [], paths: []}
  catch
    _, _ -> %{segments: [], external_dirs: [], always: [], paths: []}
  end

  defp current_cwd do
    case OptimalSystemAgent.Workspace.Cwd.get() do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> "."
    end
  rescue
    _ -> "."
  catch
    _, _ -> "."
  end

  # Reason for a risky (:ask-tier) command, enriched with the structured scan:
  # any external directories it writes to, plus the "always allow" arity pattern
  # so approving grants a scoped prefix rule rather than pinning the exact string.
  defp ask_reason(command, scan) do
    "This command is powerful (#{risk_label(command)}) — approve to run it?" <>
      external_clause(scan) <> always_clause(scan)
  end

  # Reason for a command escalated purely because it touches a path outside the
  # working directory (e.g. `cp build.txt /etc/x`).
  defp external_reason(scan) do
    "This command writes to a directory outside the working directory " <>
      "(#{Enum.join(scan.external_dirs, ", ")}) — approve to run it?" <> always_clause(scan)
  end

  defp external_clause(%{external_dirs: []}), do: ""

  defp external_clause(%{external_dirs: dirs}) do
    " It also touches paths outside the working directory: #{Enum.join(dirs, ", ")}."
  end

  defp always_clause(%{always: []}), do: ""

  defp always_clause(%{always: patterns}) do
    " (Approving always-allows: #{Enum.join(patterns, ", ")}.)"
  end

  # First word (command name) of each pipe/;/&&/|| segment of EVERY variant of
  # the command — the unquoted form and any wrapper payload included.
  #
  # Reading only the raw string let `bash -c "rm -rf /tmp/x"` past the :ask tier
  # entirely: the payload is one opaque argument, so the only head visible was
  # `bash`, which is not a risky command. See `Agent.Safety.CommandVariants`.
  defp command_heads(command) do
    command
    |> CommandVariants.variants()
    |> Enum.flat_map(&segment_heads/1)
    |> Enum.uniq()
  end

  # First word (command name) of each pipe/;/&&/|| segment, with leading
  # backslashes and any path prefix stripped (`\rm`, `/usr/bin/rm` → `rm`).
  defp segment_heads(command) do
    command
    |> String.split(~r/\s*[|;&]{1,2}\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn segment ->
      segment
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> String.replace(~r/^\\+/, "")
      |> Path.basename()
    end)
  end

  # Hard-deny tier. The `rm -rf <root>` / fork-bomb / `dd` / `mkfs` class is
  # owned by the circuit-breaker (ONE list, matched over the normalized variant
  # set); `Constants.effective_catastrophic_patterns/0` carries only the
  # extensions plus whatever the operator added via `[permissions]`, and those
  # are matched over the variants too so quoting cannot slip past them either.
  defp catastrophic?(command) do
    DangerousCommands.catastrophic_destruction?(command) or
      matches_any_variant?(command, Constants.effective_catastrophic_patterns())
  end

  defp matches_any_variant?(command, patterns) do
    CommandVariants.any?(command, fn variant ->
      Enum.any?(patterns, &Regex.match?(&1, variant))
    end)
  end

  # Operator hard-deny: any command head listed in [permissions].deny.
  defp denied?(command) do
    heads = command_heads(command)
    deny = Constants.deny_commands()
    deny != [] and Enum.any?(heads, &(&1 in deny))
  end

  # Operator allow-list: every command head is explicitly allowed, or the whole
  # command matches an allow pattern. Requiring ALL heads to be allowed keeps a
  # piped `allowed | risky` from being blanket-approved.
  defp allowed?(command) do
    allow_cmds = Constants.allow_commands()
    allow_pats = Constants.allow_patterns()

    cond do
      Enum.any?(allow_pats, &Regex.match?(&1, command)) ->
        true

      allow_cmds == [] ->
        false

      true ->
        heads = command_heads(command)
        heads != [] and Enum.all?(heads, &(&1 in allow_cmds))
    end
  end

  defp risky?(command) do
    heads = command_heads(command)

    Enum.any?(heads, &(&1 in Constants.effective_ask_commands())) or
      matches_any_variant?(command, Constants.effective_ask_patterns())
  end

  # Short human-readable reason for the permission prompt.
  defp risk_label(command) do
    heads = command_heads(command)

    cond do
      matches_any_variant?(command, Constants.effective_ask_patterns()) ->
        "runs downloaded/redirected code or force-rewrites"

      head = Enum.find(heads, &(&1 in Constants.effective_ask_commands())) ->
        head

      true ->
        "elevated action"
    end
  end

  # ── Private: execution ────────────────────────────────────────────────

  defp run_command(command, cwd, timeout_ms, session_id \\ nil, tool_call_id \\ nil) do
    # Spawn via Port (not System.cmd) so that on the timeout path we can kill
    # the underlying OS process — and on Windows its whole tree — instead of
    # only shutting down the BEAM task and leaking an orphaned child.
    sh = OptimalSystemAgent.OS.Shell.executable()
    # Redirect stdin from the null device so no command can block the port
    # waiting for interactive input (EOF is delivered immediately). stderr is
    # merged into stdout so the caller sees a single combined stream.
    #
    # The command is wrapped in a subshell — `( <command> \n ) 2>&1 < NUL` — so
    # both redirects apply to the WHOLE command, not just its last stage. Without
    # the group, `foo | wc -l 2>&1 < /dev/null` binds `< /dev/null` to `wc`,
    # starving it of the pipe's input (it reads the null device instead) and
    # breaking every pipeline whose final stage reads stdin. The closing `)` sits
    # on its own line so a trailing `# comment` on the command can't swallow it.
    wrapped = "( " <> command <> "\n) 2>&1 < " <> null_device()
    args = OptimalSystemAgent.OS.Shell.port_flags() ++ [wrapped]

    # PROCESS GROUP — spawn through `setsid -w` so the command and everything it
    # forks share one process group we can reap as a unit. Without this, killing
    # the timed-out wrapper shell leaves `npm run dev`, docker clients and
    # background servers alive as orphans holding ports and file handles. See
    # `kill_os_process/1`. When setsid is unavailable the plan falls back to the
    # bare shell and single-pid kill.
    plan = OptimalSystemAgent.OS.ProcessGroup.spawn_plan(sh, args)

    # ENVIRONMENT SCRUB — a bare Port.open hands the child the ENTIRE BEAM
    # environment, so `echo $ANTHROPIC_API_KEY` in a model-authored command reads
    # the operator's provider credentials. `OS.Env.port_env/1` unsets
    # secret-shaped names for the child only; PATH/HOME/LANG/TERM and the user's
    # own build vars are left intact.
    port =
      Port.open(
        {:spawn_executable, plan.exe},
        [
          :binary,
          :exit_status,
          :hide,
          {:args, plan.args},
          {:cd, cwd},
          {:env, OptimalSystemAgent.OS.Env.port_env()}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    # Register this process so the TUI (Ctrl+B) can find and detach the running
    # command mid-flight. Registration is best-effort: if another foreground
    # command is already registered for the session, this one simply isn't
    # detachable (unique registry) — it still runs normally.
    registered? = register_foreground(session_id)

    detach = %{
      command: command,
      cwd: cwd,
      session_id: session_id,
      tool_call_id: tool_call_id
    }

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect_command_output(port, os_pid, deadline, timeout_ms, [], detach)
    after
      if registered?, do: Registry.unregister(@registry, session_id)
    end
  rescue
    e -> {:error, "Shell execution error: #{Exception.message(e)}"}
  end

  defp register_foreground(session_id) when is_binary(session_id) do
    case Registry.register(@registry, session_id, nil) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp register_foreground(_), do: false

  defp collect_command_output(port, os_pid, deadline, timeout_ms, acc, detach) do
    collect_command_output(port, os_pid, deadline, timeout_ms, acc, detach, new_output_stream())
  end

  defp collect_command_output(port, os_pid, deadline, timeout_ms, acc, detach, stream) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        # LIVE OUTPUT STREAMING — purely additive. The chunk is still appended to
        # `acc` verbatim (the final result is byte-for-byte what it always was);
        # `stream` only carries the throttling/preview bookkeeping used to emit
        # `command_output_delta` events so the TUI can show a live tail instead of
        # a silent spinner. Emission is best-effort and can never fail the call.
        stream = accumulate_and_maybe_emit(stream, data, detach)

        collect_command_output(port, os_pid, deadline, timeout_ms, [data | acc], detach, stream)

      {^port, {:exit_status, 0}} ->
        {:ok, maybe_truncate(collected_output(acc))}

      {^port, {:exit_status, code}} ->
        {:error, "Exit #{code}:\n#{maybe_truncate(collected_output(acc))}"}

      {:detach, reply_to, ref} ->
        handle_detach(port, os_pid, acc, detach, reply_to, ref, deadline, timeout_ms, stream)
    after
      remaining ->
        # YIELD — do not kill. "Bound the wait, not the work."
        #
        # This used to SIGKILL the process and fail the tool call, which meant a
        # legitimately long command (a build, a test suite, `du` over a terabyte)
        # destroyed its own work at the deadline and took the turn down with it.
        # The deadline is really a bound on how long the AGENT should sit and
        # wait — not on how long the WORK may take.
        #
        # So on expiry the still-running process is adopted into the background
        # (the exact machinery Ctrl+B already uses), and the model gets a result
        # describing how to poll it. The command keeps running, its completion is
        # injected back into the loop by BackgroundNotifier, and the turn moves on.
        auto_detach_on_timeout(port, os_pid, acc, detach, timeout_ms)
    end
  end

  # Adopt a still-running foreground command into the background because the
  # wait window elapsed. Mirrors `handle_detach/8` (the interactive Ctrl+B path)
  # but is driven by the deadline rather than a user keystroke, so there is no
  # caller to reply to.
  defp auto_detach_on_timeout(port, os_pid, acc, detach, timeout_ms) do
    session_id = detach.session_id
    output_so_far = collected_output(acc)
    waited = div(timeout_ms, 1000)

    if is_binary(session_id) do
      OptimalSystemAgent.Agent.BackgroundNotifier.ensure_started(session_id)
    end

    case BackgroundManager.adopt(
           command: detach.command,
           cwd: detach.cwd,
           session_id: session_id,
           port: port,
           os_pid: adopted_os_pid(os_pid),
           initial: output_so_far
         ) do
      {:ok, id, child_pid} ->
        Port.connect(port, child_pid)
        safe_unlink(port)
        forward_pending_port_messages(port, child_pid)
        broadcast_command_started(session_id, id, detach.command)

        {:ok,
         "Still running after #{waited}s — moved to the background (NOT killed).\n" <>
           "- background_id: #{id}\n" <>
           "- cwd: #{detach.cwd}\n\n" <>
           partial_output_section(output_so_far) <>
           "The command is STILL RUNNING and its work is not lost. You will be " <>
           "notified automatically when it completes (with its exit code). Poll it " <>
           "with the bash_output tool using background_id \"#{id}\", or stop it with " <>
           "kill=true. Continue with other work in the meantime."}

      {:error, reason} ->
        # Adoption failed — fall back to the old destructive behaviour so a wedged
        # process can never leak, but still hand back the partial output so the
        # model can act on what was collected instead of losing it entirely.
        Logger.warning("[shell_execute] background adopt failed on timeout: #{inspect(reason)}")
        kill_os_process(os_pid)
        safe_close_port(port)

        {:error,
         "Command timed out after #{waited}s and could not be moved to the background.\n" <>
           partial_output_section(output_so_far)}
    end
  end

  # Render whatever the command printed before the wait window elapsed. Codex does
  # the same on its (rarer) hard-timeout path: returning partial output lets the
  # model act on it or retry with a larger budget instead of getting nothing.
  defp partial_output_section(""), do: ""

  defp partial_output_section(output) do
    "Output so far:\n" <> maybe_truncate(output) <> "\n\n"
  end

  # Hand the live OS process off to a supervised BackgroundTask, then return a
  # "moved to background" result so the current turn completes. The worker takes
  # over the port (via Port.connect) and later broadcasts a
  # background_command_completed event just like any other background command.
  defp handle_detach(port, os_pid, acc, detach, reply_to, ref, deadline, timeout_ms, stream) do
    session_id = detach.session_id
    output_so_far = collected_output(acc)

    # Ensure a notifier is listening BEFORE the worker can finish, so the
    # completion is injected back into the Loop (mirrors run_in_background/3).
    if is_binary(session_id) do
      OptimalSystemAgent.Agent.BackgroundNotifier.ensure_started(session_id)
    end

    case BackgroundManager.adopt(
           command: detach.command,
           cwd: detach.cwd,
           session_id: session_id,
           port: port,
           os_pid: adopted_os_pid(os_pid),
           initial: output_so_far
         ) do
      {:ok, id, child_pid} ->
        # Transfer port ownership to the worker, then unlink so THIS process
        # exiting can never take the port (and its OS child) down. Finally,
        # forward any port messages already sitting in our mailbox.
        Port.connect(port, child_pid)
        safe_unlink(port)
        forward_pending_port_messages(port, child_pid)
        broadcast_command_started(session_id, id, detach.command)
        send(reply_to, {:detached, ref, id})

        {:ok,
         "Moved to background.\n" <>
           "- background_id: #{id}\n" <>
           "- cwd: #{detach.cwd}\n\n" <>
           "The command keeps running in the background; you'll be notified " <>
           "automatically when it completes (with its exit code). Poll it with " <>
           "the bash_output tool using background_id \"#{id}\", or stop it with kill=true."}

      {:error, reason} ->
        # Adoption failed — keep running in the foreground as if nothing happened.
        send(reply_to, {:detach_failed, ref, reason})
        collect_command_output(port, os_pid, deadline, timeout_ms, acc, detach, stream)
    end
  end

  defp safe_unlink(port) do
    :erlang.unlink(port)
    :ok
  rescue
    _ -> :ok
  end

  # Drain any {port, msg} tuples already delivered to this mailbox (before the
  # ownership transfer) and forward them to the worker, which handles the same
  # {port, {:data,…}} / {port, {:exit_status,…}} shapes.
  defp forward_pending_port_messages(port, child_pid) do
    receive do
      {^port, msg} ->
        send(child_pid, {port, msg})
        forward_pending_port_messages(port, child_pid)
    after
      0 -> :ok
    end
  end

  defp broadcast_command_started(session_id, id, command) when is_binary(session_id) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :background_command_started,
         background_id: id,
         command: command,
         session_id: session_id,
         running_count: BackgroundManager.running_count()
       }}
    )

    :ok
  rescue
    _ -> :ok
  end

  defp broadcast_command_started(_, _, _), do: :ok

  # ── Live command output streaming ─────────────────────────────────────
  #
  # A long foreground command used to show the user nothing but a spinner for
  # its entire run. Codex solves this by emitting an output delta per pipe read
  # (`core/src/exec.rs`: READ_CHUNK_SIZE chunks, capped at
  # MAX_EXEC_OUTPUT_DELTAS_PER_CALL = 10_000 events, but the pipe KEEPS being
  # drained after the cap so a chatty command never blocks on a full pipe).
  #
  # We do the same, with one addition: the BEAM delivers port data as fast as
  # the OS produces it, so raw per-chunk emission would flood PubSub/SSE. Deltas
  # are therefore coalesced and emitted at most once per
  # `@output_delta_interval_ms` (~4/sec). Draining is unaffected — after the cap
  # (or between emit windows) chunks are still received and appended to `acc`,
  # exactly as before.
  #
  # This path is strictly additive: it never touches `acc`, never changes a
  # return value, and every emit is wrapped so a PubSub failure is swallowed.

  # Max emitted events per call (Codex MAX_EXEC_OUTPUT_DELTAS_PER_CALL).
  @max_output_deltas_per_call 10_000
  # Throttle window: at most ~4 events/second.
  @output_delta_interval_ms 250
  # Rolling snapshot of the end of the output carried on every event, so a TUI
  # that connected late (or dropped frames) can resync without replay.
  @output_delta_tail_bytes 2_048
  # Hard cap on a single coalesced delta so one burst can't produce a huge frame.
  @output_delta_max_chunk_bytes 8_192

  defp new_output_stream do
    %{last_emit_ms: nil, emitted: 0, pending: [], pending_bytes: 0, tail: "", seq: 0}
  end

  # Fold a freshly-received port chunk into the streaming state, emitting a
  # `command_output_delta` when the throttle window has elapsed and the per-call
  # event cap has not been reached. Returns the new state; never raises.
  defp accumulate_and_maybe_emit(stream, data, %{session_id: session_id} = detach)
       when is_binary(session_id) do
    tail = clip_tail(stream.tail <> data)
    now = System.monotonic_time(:millisecond)

    stream = %{
      stream
      | tail: tail,
        pending: [data | stream.pending],
        pending_bytes: stream.pending_bytes + byte_size(data)
    }

    cond do
      # Cap reached — stop emitting but KEEP draining (the caller still appends
      # to `acc`). Drop the pending buffer so a chatty command can't grow memory
      # with deltas that will never be sent.
      stream.emitted >= @max_output_deltas_per_call ->
        %{stream | pending: [], pending_bytes: 0}

      # Inside the throttle window — coalesce, emit on a later chunk.
      is_integer(stream.last_emit_ms) and now - stream.last_emit_ms < @output_delta_interval_ms ->
        stream

      true ->
        chunk = stream.pending |> Enum.reverse() |> IO.iodata_to_binary() |> clip_chunk()

        broadcast_output_delta(
          session_id,
          detach.command,
          chunk,
          tail,
          stream.seq,
          Map.get(detach, :tool_call_id)
        )

        %{
          stream
          | pending: [],
            pending_bytes: 0,
            last_emit_ms: now,
            emitted: stream.emitted + 1,
            seq: stream.seq + 1
        }
    end
  rescue
    _ -> stream
  catch
    _, _ -> stream
  end

  # No session to stream to (background worker, unit test, headless call) — do
  # no bookkeeping at all so the hot loop stays exactly as cheap as before.
  defp accumulate_and_maybe_emit(stream, _data, _detach), do: stream

  defp clip_tail(bin) when byte_size(bin) <= @output_delta_tail_bytes, do: bin

  defp clip_tail(bin),
    do: binary_part(bin, byte_size(bin) - @output_delta_tail_bytes, @output_delta_tail_bytes)

  defp clip_chunk(bin) when byte_size(bin) <= @output_delta_max_chunk_bytes, do: bin

  defp clip_chunk(bin) do
    kept =
      binary_part(
        bin,
        byte_size(bin) - @output_delta_max_chunk_bytes,
        @output_delta_max_chunk_bytes
      )

    "…\n" <> kept
  end

  # Same transport as `broadcast_command_started/3`: a direct broadcast on the
  # per-session PubSub topic the SSE loop streams. Because it is broadcast
  # directly (not via `Events.Bus`), no `Events.TuiForwarder` allowlist entry is
  # needed — the forwarder only bridges Bus-only sub-events, and adding it there
  # would double-emit.
  defp broadcast_output_delta(session_id, command, chunk, tail, seq, tool_call_id)
       when is_binary(session_id) do
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:session:#{session_id}",
      {:osa_event,
       %{
         type: :command_output_delta,
         session_id: session_id,
         command: command,
         # Owning tool_call id. The COMMAND STRING is not a key: two concurrent
         # runs of the same command are indistinguishable by it, and a client
         # keyed on it interleaves (or repeatedly clears) their output.
         tool_call_id: tool_call_id,
         chunk: ensure_utf8(chunk),
         tail: ensure_utf8(tail),
         seq: seq
       }}
    )

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp broadcast_output_delta(_, _, _, _, _, _), do: :ok

  defp collected_output(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # The pid handed to BackgroundManager on adoption.
  #
  # `os_pid` is the `setsid -w` wrapper. BackgroundManager stops a task with a
  # plain single-pid `kill`, so giving it the WRAPPER pid would kill setsid and
  # leave the command running — strictly worse than before the group change.
  # Give it the group LEADER instead: that is the command shell, exactly the pid
  # this code used to register when there was no setsid wrapper.
  #
  # `BackgroundTask.do_kill/2` reaps the leader's whole group via
  # `ProcessGroup.pgid_of/1`, so a backgrounded command's descendants are
  # collected the same way a foreground timeout collects them.
  defp adopted_os_pid(nil), do: nil

  defp adopted_os_pid(os_pid) do
    OptimalSystemAgent.OS.ProcessGroup.leader_pid(os_pid) || os_pid
  end

  defp kill_os_process(nil), do: :ok

  # Kill the command AND EVERYTHING IT SPAWNED.
  #
  # `os_pid` is the `setsid -w` wrapper (see `run_command/5`). Its sole child is
  # the group leader, so the pgid resolves deterministically from it while the
  # wrapper is still alive — which it is, because `-w` makes setsid wait for the
  # command. Signalling `-<pgid>` reaches the whole tree.
  #
  # This used to send `kill -TERM <pid>` immediately followed by `kill -KILL
  # <pid>` on the wrapper shell alone: no group, and no grace window, so the
  # TERM was functionally a KILL and every descendant survived as an orphan.
  #
  # The pgid resolution is guarded by `ProcessGroup.killpg_safe?/1`, which
  # refuses pgid <= 1 and this node's own group; if the group cannot be resolved
  # safely we fall back to the single pid rather than guessing at a group.
  defp kill_os_process(os_pid) do
    alias OptimalSystemAgent.OS.ProcessGroup

    case :os.type() do
      {:win32, _} ->
        _ =
          System.cmd("taskkill", ["/PID", to_string(os_pid), "/T", "/F"], stderr_to_stdout: true)

      _ ->
        case ProcessGroup.resolve_pgid(os_pid) do
          nil ->
            ProcessGroup.terminate_pid(os_pid)

          pgid ->
            case ProcessGroup.terminate_group(pgid) do
              :ok -> ProcessGroup.terminate_pid(os_pid, 0)
              {:error, :unsafe_pgid} -> ProcessGroup.terminate_pid(os_pid)
            end
        end
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # Fraction of the byte budget kept from the HEAD; the rest is the tail.
  # Head-weighted because the command being run, its banner and the first errors
  # live there, but the tail is never zero — see below.
  @truncate_head_ratio 0.4

  defp maybe_truncate(output) do
    max = Constants.max_output_bytes()

    bounded =
      if byte_size(output) > max do
        # HEAD AND TAIL, not head only.
        #
        # This used to keep `binary_part(output, 0, max)` and throw the rest
        # away. For the commands that actually overflow the cap — a build, a
        # test run, a long install — the compiler errors, the failure summary
        # and the exit diagnostics are all at the END. Head-only truncation
        # discarded exactly the bytes the turn depended on and handed the model
        # a screenful of progress spinners instead.
        #
        # `max` is a BYTE budget; String.slice/3 counts CHARACTERS, so multibyte
        # output could pass ~4x the cap. binary_part keeps the cap honest, and
        # `ensure_utf8/1` below repairs the codepoint that either cut may split.
        head_bytes = trunc(max * @truncate_head_ratio)
        tail_bytes = max - head_bytes

        head = binary_part(output, 0, head_bytes)
        tail = binary_part(output, byte_size(output) - tail_bytes, tail_bytes)

        omitted_bytes = byte_size(output) - max

        omitted_lines =
          output
          |> binary_part(head_bytes, omitted_bytes)
          |> count_newlines()

        head <> elision_marker(omitted_bytes, omitted_lines) <> tail
      else
        output
      end

    # Coerce to valid UTF-8: raw command bytes (e.g. binary blobs) would
    # otherwise break the JSON serialization of the tool result downstream.
    ensure_utf8(bounded)
  end

  defp elision_marker(omitted_bytes, omitted_lines) do
    "\n\n[... output truncated: #{omitted_lines} lines / #{omitted_bytes} bytes omitted from the middle; " <>
      "the head and the tail are shown in full ...]\n\n"
  end

  defp count_newlines(bin), do: count_newlines(bin, 0)
  defp count_newlines(<<>>, acc), do: acc
  defp count_newlines(<<?\n, rest::binary>>, acc), do: count_newlines(rest, acc + 1)
  defp count_newlines(<<_, rest::binary>>, acc), do: count_newlines(rest, acc)

  defp ensure_utf8(bin) do
    if String.valid?(bin), do: bin, else: IO.iodata_to_binary(scrub_utf8(bin, []))
  end

  defp scrub_utf8(<<>>, acc), do: Enum.reverse(acc)
  defp scrub_utf8(<<c::utf8, rest::binary>>, acc), do: scrub_utf8(rest, [<<c::utf8>> | acc])
  defp scrub_utf8(<<_bad, rest::binary>>, acc), do: scrub_utf8(rest, [<<0xFFFD::utf8>> | acc])
end
