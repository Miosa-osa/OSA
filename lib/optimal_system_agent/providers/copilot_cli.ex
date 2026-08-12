defmodule OptimalSystemAgent.Providers.CopilotCli do
  @moduledoc """
  Inference through GitHub's **Copilot CLI**, driven as a subprocess.

  Same architectural shape as `Providers.ClaudeCli` — an external CLI holds
  the credential, OSA spawns it per request and keeps its own agent loop —
  but a deliberately separate implementation. The event schema, the
  loop-suppression mechanism and the auth model all differ, and a shared
  abstraction over two cases would have hidden exactly the differences that
  matter. What generalises is the *pattern*, and that is reused; what does
  not, is not.

  ## Taking the agent loop back

  Left alone, `copilot` is an agent, not a model: given a prompt it will call
  `view`, then `bash`, then answer — a multi-turn loop executing tools under
  **its** permission model, entirely outside OSA's tool executor, permission
  prompts and audit trail. Shipping that behind OSA's model picker would mean
  a user selects a "model" and silently gets a different agent editing their
  files.

  The lever that prevents it is `--available-tools`, and the working value is
  counter-intuitive enough to be worth stating: `--available-tools=` (empty)
  is **ignored** and tools stay live. `--available-tools=osa_none` — naming a
  tool that does not exist — leaves the model with no tools at all. Verified
  against CLI 1.0.79: `toolRequests: []`, no `tool.execution_*` events, one
  turn. Do not "clean this up" to an empty value.

  Full flag set, each earning its place:

      --output-format json      newline-delimited events, not prose
      --available-tools=osa_none  no Copilot tools ⇒ no Copilot agent loop
      --disable-builtin-mcps    no GitHub MCP server
      --no-ask-user             never block waiting on a human
      --no-custom-instructions  ignore the repo's AGENTS.md — OSA supplies steering
      --no-remote --no-remote-export   the session is not published to GitHub
      --no-auto-update          a provider call must not mutate the user's toolchain

  ## What OSA gives up on this path

    * **No system-prompt channel.** Unlike `claude -p`, Copilot has no
      `--system-prompt`. OSA's steering goes inline in the prompt text, and
      Copilot's own agent preamble is still prepended by the CLI (it injects
      `<current_datetime>` and `<system_reminder>` blocks). So OSA's system
      prompt *competes with* Copilot's rather than replacing it. This is a
      real fidelity cost and the main reason to prefer `claude_cli` where
      both are available.
    * **Tool calls are text.** Same mechanism as `claude_cli`: tools declared
      in the prompt, `<tool_call>{…}</tool_call>` parsed back out via the
      existing `ToolCallParsers` hermes dialect.
    * **Model choice is mostly Copilot's.** See `default_model/0`.
    * **Process spawn per request**, and a slower start than `claude -p`
      (MCP teardown and session bookkeeping still run).

  ## What is deliberately not done

  No `copilot_internal/v2/token` exchange and no borrowed editor client id —
  the route other third-party tools take to reach Copilot's API directly. It
  works, but it depends on an undocumented internal endpoint and on
  impersonating a first-party application, and the account carrying that risk
  is the user's. Here GitHub's own client makes the request.
  """

  require Logger

  alias OptimalSystemAgent.Auth.Providers.CopilotCli, as: Auth
  alias OptimalSystemAgent.Providers.ToolCallParsers

  @behaviour OptimalSystemAgent.Providers.Behaviour

  # "auto" is not a placeholder — it is Copilot's own router, and omitting
  # `--model` is the only reliably-correct choice. Observed on 1.0.79:
  # `--model claude-haiku-4.5` was REJECTED as "not available" while the
  # auto-router simultaneously selected that exact model for the same
  # account. The flag validates against a different list than the router
  # uses, so passing a model OSA merely believes is available is a way to
  # fail a turn that would otherwise have worked.
  @default_model "auto"

  @tool_open "<tool_call>"
  @default_timeout_ms 600_000

  @impl true
  @spec name() :: atom()
  def name, do: :copilot_cli

  @impl true
  @spec default_model() :: String.t()
  def default_model,
    do: Application.get_env(:optimal_system_agent, :copilot_cli_model, @default_model)

  @doc """
  Models this account can actually use, as reported by the CLI's own router
  on the last call, plus `auto`.

  Deliberately NOT a hardcoded list. Copilot's catalogue is per-account and
  changes without OSA's involvement; the only trustworthy source is the
  `session.auto_mode_resolved` event, which names `availableModels` for the
  signed-in account. Before the first call this is just `["auto"]` — one
  honest entry rather than a plausible fiction.
  """
  @impl true
  @spec available_models() :: [String.t()]
  def available_models do
    ["auto" | :persistent_term.get({__MODULE__, :available_models}, [])]
  end

  @doc "True when the Copilot CLI is installed and OSA has a marker for it. Pure read."
  @spec configured?() :: boolean()
  def configured?, do: Auth.installed?() and Auth.status().connected?

  @doc "The model the CLI's router last actually used, or `nil`."
  @spec last_resolved_model() :: String.t() | nil
  def last_resolved_model, do: :persistent_term.get({__MODULE__, :resolved_model}, nil)

  @doc "Usage from the CLI's final `result` event for the last call, verbatim, or `nil`."
  @spec last_usage() :: map() | nil
  def last_usage, do: :persistent_term.get({__MODULE__, :usage}, nil)

  # ── Public API ──────────────────────────────────────────────────────────

  @impl true
  @spec chat(list(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def chat(messages, opts \\ []) do
    case run(messages, opts, nil) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  @impl true
  @spec chat_stream(list(), function(), keyword()) :: :ok | {:error, String.t()}
  def chat_stream(messages, callback, opts \\ []) when is_function(callback, 1) do
    case run(messages, opts, callback) do
      {:ok, result} ->
        callback.({:done, result})
        :ok

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  # ── Execution ───────────────────────────────────────────────────────────

  defp run(messages, opts, callback) do
    with {:ok, bin} <- resolve_binary(),
         {:ok, sh} <- resolve_shell() do
      {system, turns} = OptimalSystemAgent.Providers.ClaudeCli.split_system(messages)
      tools = Keyword.get(opts, :tools) || []

      prompt =
        OptimalSystemAgent.Providers.ClaudeCli.build_system_prompt(system, tools) <>
          "\n\n" <> OptimalSystemAgent.Providers.ClaudeCli.render_turns(turns)

      with {:ok, dir, file} <- write_stdin(prompt) do
        try do
          spawn_and_collect(sh, cli_args(bin, opts), file, callback, timeout(opts))
        after
          File.rm_rf(dir)
        end
      end
    end
  end

  defp resolve_binary do
    case Auth.binary() do
      nil -> {:error, :cli_not_installed}
      bin -> {:ok, bin}
    end
  end

  defp resolve_shell do
    case System.find_executable("sh") do
      nil -> {:error, :no_shell}
      sh -> {:ok, sh}
    end
  end

  defp timeout(opts) do
    Keyword.get(opts, :receive_timeout) ||
      Application.get_env(:optimal_system_agent, :copilot_cli_timeout_ms, @default_timeout_ms)
  end

  defp cli_args(bin, opts) do
    base = [
      bin,
      "--output-format",
      "json",
      # See the moduledoc. An existing-but-nonexistent tool name is what
      # actually disables tools; an empty value does not.
      "--available-tools=osa_none",
      "--disable-builtin-mcps",
      "--no-ask-user",
      "--no-custom-instructions",
      "--no-remote",
      "--no-remote-export",
      "--no-auto-update"
    ]

    # Only pass --model when the caller named a real one. "auto" means "let
    # Copilot route", which is expressed by omitting the flag entirely.
    case Keyword.get(opts, :model) || default_model() do
      m when is_binary(m) and m != "" and m != "auto" -> base ++ ["--model", m]
      _ -> base
    end
  end

  # No prompt in argv: Copilot's `-p/--prompt` takes the text as a command
  # line value, which would publish the whole conversation to every local
  # user via `ps`. Verified on 1.0.79 that the CLI reads the prompt from
  # stdin when `-p` is omitted, so that is the path used.
  @shell_script ~S(exec "$0" "$@" < "$OSA_COPILOT_STDIN" 2> "$OSA_COPILOT_STDERR")

  defp child_env(stdin_path, stderr_path) do
    [
      {~c"OSA_COPILOT_STDIN", String.to_charlist(stdin_path)},
      {~c"OSA_COPILOT_STDERR", String.to_charlist(stderr_path)},
      {~c"NO_COLOR", ~c"1"},
      # A provider call must not mutate the user's toolchain mid-turn.
      {~c"COPILOT_AUTO_UPDATE", ~c"false"}
    ]
  end

  defp spawn_and_collect(sh, args, stdin_path, callback, timeout_ms) do
    stderr_path = stdin_path <> ".err"

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        :hide,
        {:args, ["-c", @shell_script | args]},
        # Scrub first so the CLI cannot see other providers' credentials, and
        # so an inherited GITHUB_TOKEN cannot silently answer for a different
        # account than the one the user connected — the same reasoning as
        # `Auth.Providers.CopilotCli.probe_env/0`. `child_env/2` is applied on
        # top, so the stdin/stderr paths and NO_COLOR survive.
        {:env, OptimalSystemAgent.OS.Env.port_env(child_env(stdin_path, stderr_path))}
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect(port, deadline, callback, %{
        buffer: "",
        text: "",
        stream_text: "",
        emitted: 0,
        suppressed?: false,
        error: nil,
        stderr: "",
        stderr_path: stderr_path
      })
    after
      safe_close(port)
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp collect(port, deadline, callback, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {^port, {:data, chunk}} ->
          {lines, rest} = split_lines(acc.buffer <> chunk)
          acc = Enum.reduce(lines, %{acc | buffer: rest}, &handle_line(&1, &2, callback))
          collect(port, deadline, callback, acc)

        {^port, {:exit_status, status}} ->
          finish(flush(acc, callback), status)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {rest, lines} = List.pop_at(parts, -1)
    {lines, rest}
  end

  defp handle_line(line, acc, callback) do
    case Jason.decode(String.trim(line)) do
      {:ok, event} when is_map(event) ->
        handle_event(event, acc, callback)

      _ ->
        case String.trim(line) do
          "" -> acc
          other -> %{acc | stderr: acc.stderr <> other <> "\n"}
        end
    end
  end

  # The router's own account-specific catalogue, and the model it chose.
  # Recorded rather than guessed — see `available_models/0`.
  defp handle_event(%{"type" => "session.auto_mode_resolved", "data" => data}, acc, _cb) do
    case data["availableModels"] do
      list when is_list(list) ->
        :persistent_term.put({__MODULE__, :available_models}, Enum.filter(list, &is_binary/1))

      _ ->
        :ok
    end

    remember_model(data["chosenModel"])
    acc
  end

  defp handle_event(%{"type" => "assistant.message_delta", "data" => data}, acc, callback) do
    case data["deltaContent"] do
      text when is_binary(text) -> emit_text(text, acc, callback)
      _ -> acc
    end
  end

  defp handle_event(%{"type" => "assistant.message", "data" => data}, acc, _callback) do
    remember_model(data["model"])
    %{acc | text: acc.text <> to_string(data["content"] || "")}
  end

  defp handle_event(%{"type" => "result"} = result, acc, _callback) do
    :persistent_term.put({__MODULE__, :usage}, result["usage"])

    case result["exitCode"] do
      0 -> acc
      nil -> acc
      code -> %{acc | error: {:cli_exit, code, ""}}
    end
  end

  # Copilot reports its own errors as events too.
  defp handle_event(%{"type" => "error", "data" => data}, acc, _callback) do
    %{acc | error: {:cli_error, to_string(data["message"] || inspect(data))}}
  end

  defp handle_event(_other, acc, _callback), do: acc

  defp emit_text(text, acc, callback) do
    acc = %{acc | stream_text: acc.stream_text <> text}

    cond do
      is_nil(callback) ->
        acc

      acc.suppressed? ->
        acc

      true ->
        case :binary.match(acc.stream_text, @tool_open) do
          {pos, _} ->
            emit_upto(acc, pos, callback) |> Map.put(:suppressed?, true)

          :nomatch ->
            safe = max(byte_size(acc.stream_text) - (byte_size(@tool_open) - 1), 0)
            emit_upto(acc, safe, callback)
        end
    end
  end

  defp flush(acc, callback) when is_function(callback, 1) do
    if acc.suppressed?, do: acc, else: emit_upto(acc, byte_size(acc.stream_text), callback)
  end

  defp flush(acc, _callback), do: acc

  defp emit_upto(acc, upto, callback) do
    if upto > acc.emitted do
      slice = binary_part(acc.stream_text, acc.emitted, upto - acc.emitted)
      if slice != "", do: callback.({:text_delta, slice})
      %{acc | emitted: upto}
    else
      acc
    end
  end

  defp finish(%{error: error} = acc, _status) when not is_nil(error),
    do: {:error, with_diagnostics(error, acc)}

  defp finish(acc, 0) do
    raw = if acc.text == "", do: acc.stream_text, else: acc.text
    {:ok, %{content: clean(raw), tool_calls: ToolCallParsers.parse(raw, "hermes")}}
  end

  defp finish(acc, status), do: {:error, with_diagnostics({:cli_exit, status, ""}, acc)}

  defp with_diagnostics({tag, code, _}, acc), do: {tag, code, diagnostics(acc)}
  defp with_diagnostics({:cli_error, msg}, _acc), do: {:cli_error, msg}

  defp diagnostics(acc) do
    [acc.stderr, read_stderr(acc)]
    |> Enum.map_join("\n", &String.trim/1)
    |> String.trim()
    |> truncate(600)
  end

  defp read_stderr(%{stderr_path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, data} -> data
      _ -> ""
    end
  end

  defp read_stderr(_), do: ""

  defp truncate(s, max) when byte_size(s) > max, do: binary_part(s, 0, max) <> "…"
  defp truncate(s, _max), do: s

  defp clean(text) do
    text
    |> String.replace(~r{<tool_call>.*?</tool_call>}s, "")
    |> String.trim()
  end

  defp remember_model(model) when is_binary(model) and model != "" do
    :persistent_term.put({__MODULE__, :resolved_model}, model)
    :ok
  end

  defp remember_model(_), do: :ok

  # ── stdin file ──────────────────────────────────────────────────────────

  defp write_stdin(prompt) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "osa-copilot-#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive])}"
      )

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         file = Path.join(dir, "input.txt"),
         :ok <- File.write(file, prompt),
         :ok <- File.chmod(file, 0o600) do
      {:ok, dir, file}
    else
      {:error, reason} -> {:error, {:tmp_write_failed, reason}}
    end
  end

  # ── errors ──────────────────────────────────────────────────────────────

  @doc false
  @spec error_message(term()) :: String.t()
  def error_message(:cli_not_installed),
    do:
      "The GitHub Copilot CLI is not installed (or not on PATH). Install it with " <>
        "`npm install -g @github/copilot`, or set OSA_COPILOT_CLI_BIN to its full path."

  def error_message(:no_shell),
    do: "OSA could not find a POSIX shell to launch the Copilot CLI with."

  def error_message(:timeout),
    do:
      "The Copilot CLI did not finish in time. Long turns can be extended with " <>
        "config `:copilot_cli_timeout_ms`."

  def error_message({:cli_error, msg}), do: "Copilot reported an error: #{msg}"

  def error_message({:cli_exit, status, ""}),
    do:
      "The Copilot CLI exited with status #{status} and said nothing. If this is the first turn, " <>
        "check you are signed in with `copilot login` — OSA cannot verify that without making a billed request."

  def error_message({:cli_exit, status, detail}),
    do: "The Copilot CLI exited with status #{status}: #{detail}"

  def error_message({:tmp_write_failed, reason}),
    do: "Could not write a private temporary file for the request: #{inspect(reason)}"

  def error_message(other), do: "Copilot CLI bridge failed: #{inspect(other)}"
end
