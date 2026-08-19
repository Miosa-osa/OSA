defmodule OptimalSystemAgent.Providers.ClaudeCli do
  @moduledoc """
  Inference through the **Claude Code CLI**, driven as a subprocess.

  This is the transport half of the sanctioned Anthropic subscription path
  (see `Auth.Providers.ClaudeCli` for why it is the sanctioned one). The Agent
  SDK documentation blesses exactly this shape for a harness that is neither
  TypeScript nor Python: *run the CLI as a subprocess with `-p` and
  `--output-format stream-json`.*

  ## OSA keeps its own loop. That was not a given.

  The obvious way to build this bridge is to hand Claude Code the task and
  render its events — which is what the Pi bridges do, and why they document
  expensive session rebuilds and edits lost across them. OSA does the
  opposite, and it is worth stating exactly how, because the flags are what
  make it possible:

      --tools ""            no built-in Claude Code tools
      --setting-sources ""  no user/project settings, hooks, or CLAUDE.md
      --strict-mcp-config   no MCP servers from the user's config
      --system-prompt-file …  OSA's system prompt REPLACES Claude Code's
      --no-session-persistence
      --max-turns 1

  With those, `claude -p` is a stateless inference call: OSA's prompt, OSA's
  conversation, one assistant turn back. OSA's agent loop, permission model,
  tool executor, compaction and steering are all untouched. Verified against
  CLI 2.1.226: with `--system-prompt` set, the request carried 207 input
  tokens and zero cache-creation tokens, i.e. Claude Code's own ~27k-token
  system prompt was genuinely gone rather than merely appended to.

  ## What OSA gives up on this path

  Stated here rather than discovered later:

    * **Tool calls are text, not structured.** `claude -p` has no flag to pass
      arbitrary tool schemas to the model, so OSA declares its tools in the
      system prompt and parses `<tool_call>{…}</tool_call>` back out with the
      existing `ToolCallParsers` (the same mechanism OSA already relies on for
      local models). This is less reliable than native tool calling: a model
      can malform the JSON, and there is no server-side schema enforcement.
    * **Process spawn per request** — roughly a second of startup before any
      token arrives, on top of normal latency.
    * **No streaming of tool arguments.** Text before a `<tool_call>` marker
      streams; once the model starts a call, output is withheld until the turn
      completes rather than rendering raw XML into the transcript.
    * **Whatever the CLI decides.** Model aliases, quota windows and error
      text come from Claude Code. OSA reports what the CLI reports, including
      the concrete model id it resolved an alias to.
    * **No API-key mode here.** A key belongs on the `anthropic` provider,
      which is untouched and speaks the real API directly.

  ## What is deliberately not done

  No forged `cch` checksum, no `cc_version` hash, no `x-anthropic-billing-header`
  system block, no `claude-cli/…` user agent, no reading of `~/.claude.json`
  for the user's device or account id. Those techniques exist, in public, to
  defeat Anthropic's first-party/third-party billing discriminator. OSA does
  not implement them and must not: this provider works *because* it is
  Anthropic's own client making the request, which is also why nothing here
  needs to lie about what it is.
  """

  require Logger

  alias OptimalSystemAgent.Auth.Providers.ClaudeCli, as: Auth
  alias OptimalSystemAgent.Providers.ToolCallParsers

  @behaviour OptimalSystemAgent.Providers.Behaviour

  @default_model "sonnet"

  # Aliases the CLI itself documents under `--model`. Deliberately NOT dated
  # model ids: which concrete model an alias resolves to is Claude Code's
  # decision and changes without OSA being involved, so a hardcoded
  # `claude-…-20250101` here would be a confident lie the first time Anthropic
  # ships a new one. The real id is reported back from `message_start` after
  # the first call — see `last_resolved_model/0`.
  #
  # `fable` was missing until it was read back off `claude --help`, which names
  # "'fable', 'opus', or 'sonnet'" as its examples. A subscriber could run it
  # and OSA never offered it — the same way the Codex catalogue silently aged
  # out. Re-check this against `claude --help` when the CLI updates; it is the
  # only source that cannot disagree with the binary actually installed.
  @models ["fable", "opus", "sonnet", "haiku"]

  # The tool-call marker OSA asks for. `<tool_call>` is what
  # `ToolCallParsers.parse_hermes/1` reads, so this reuses a parser that is
  # already exercised by the local-model path rather than adding an eighth
  # dialect.
  @tool_open "<tool_call>"

  @default_timeout_ms 600_000

  @impl true
  @spec name() :: atom()
  def name, do: :claude_cli

  @impl true
  @spec default_model() :: String.t()
  def default_model,
    do: Application.get_env(:optimal_system_agent, :claude_cli_model, @default_model)

  @impl true
  @spec available_models() :: [String.t()]
  def available_models, do: @models

  @doc "True when Claude Code is installed and OSA has recorded a usable sign-in. Pure read."
  @spec configured?() :: boolean()
  def configured?, do: Auth.installed?() and Auth.status().connected?

  # ── Public API ──────────────────────────────────────────────────────────

  @impl true
  @spec chat(list(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def chat(messages, opts \\ []) do
    case run(messages, opts, nil) do
      # Passed through whole rather than reconstructed from two keys. The old
      # shape rebuilt `%{content:, tool_calls:}` and DROPPED everything else
      # `finish/2` produced — which is how the usage below stayed invisible.
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

  @doc """
  The concrete model id the CLI last resolved an alias to (e.g.
  `claude-haiku-4-5-20251001`), or `nil` before the first successful call.

  Exists so status surfaces can name what actually ran instead of echoing the
  alias the user picked. OSA has shipped a banner reporting a model it was not
  running before; this is the cheap way not to do it again.
  """
  @spec last_resolved_model() :: String.t() | nil
  def last_resolved_model, do: :persistent_term.get({__MODULE__, :resolved_model}, nil)

  @doc """
  Usage and quota reported by the CLI's final `result` event for the last
  call, or `nil`. Keys are exactly what the CLI sent — no invented fields.
  """
  @spec last_usage() :: map() | nil
  def last_usage, do: :persistent_term.get({__MODULE__, :usage}, nil)

  # ── Execution ───────────────────────────────────────────────────────────

  defp run(messages, opts, callback) do
    with {:ok, bin} <- resolve_binary(),
         {:ok, sh} <- resolve_shell() do
      model = Keyword.get(opts, :model) || default_model()
      {system, turns} = split_system(messages)
      tools = Keyword.get(opts, :tools) || []

      system_prompt = build_system_prompt(system, tools)
      stdin_line = stream_json_user(render_turns(turns))

      with {:ok, dir, file, prompt_file} <- write_request_files(stdin_line, system_prompt) do
        try do
          args = cli_args(bin, model, prompt_file, callback != nil)
          spawn_and_collect(sh, args, file, callback, timeout(opts))
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

  # `sh` is used for exactly one thing: `< "$OSA_CLAUDE_STDIN"`. An Erlang
  # port cannot close a child's stdin without tearing down the whole port, and
  # `claude --input-format stream-json` waits for EOF before it answers. The
  # alternative — passing the conversation as an argv element — would publish
  # the entire prompt to every local user via `ps`. The script is a fixed
  # string with no interpolation; the binary arrives as `$0`, its flags as
  # `$@`, and the file path through the environment, so nothing user-supplied
  # is ever parsed by the shell.
  defp resolve_shell do
    case System.find_executable("sh") do
      nil -> {:error, :no_shell}
      sh -> {:ok, sh}
    end
  end

  defp timeout(opts) do
    Keyword.get(opts, :receive_timeout) ||
      Application.get_env(:optimal_system_agent, :claude_cli_timeout_ms, @default_timeout_ms)
  end

  # The system prompt travels as a file, not an argv element. Linux caps a
  # single argv string at 128KiB (MAX_ARG_STRLEN); OSA's built prompt —
  # SYSTEM.md plus the tool protocol plus per-session injections — sits near
  # that ceiling and has crossed it, at which point execve fails with E2BIG
  # (errno 7) before the CLI even starts. A file has no such ceiling, and it
  # also keeps the prompt out of `ps` output, same as the conversation.
  defp cli_args(bin, model, system_prompt_file, streaming?) do
    base = [
      bin,
      "-p",
      "--output-format",
      "stream-json",
      "--input-format",
      "stream-json",
      "--verbose",
      "--model",
      model,
      "--max-turns",
      "1",
      # No Claude Code tools, no user hooks/settings/CLAUDE.md, no MCP
      # servers, no session files. Everything the model sees comes from OSA.
      "--tools",
      "",
      "--setting-sources",
      "",
      "--strict-mcp-config",
      "--no-session-persistence",
      "--system-prompt-file",
      system_prompt_file
    ]

    if streaming?, do: base ++ ["--include-partial-messages"], else: base
  end

  # Child environment. `ANTHROPIC_API_KEY` is cleared for the same reason the
  # auth probe clears it: inheriting one would quietly move the user from
  # plan-metered to per-token billing on a provider they chose precisely
  # because it does not do that. `CLAUDE_CODE_OAUTH_TOKEN` is passed through
  # untouched if the user set it — that is Anthropic's own documented
  # mechanism for a headless box, and OSA neither mints nor stores it.
  defp child_env(stdin_path, stderr_path) do
    [
      {~c"OSA_CLAUDE_STDIN", String.to_charlist(stdin_path)},
      {~c"OSA_CLAUDE_STDERR", String.to_charlist(stderr_path)},
      {~c"ANTHROPIC_API_KEY", false},
      {~c"ANTHROPIC_AUTH_TOKEN", false},
      {~c"ANTHROPIC_BASE_URL", false},
      # Colour codes in a machine-read stream are noise at best.
      {~c"NO_COLOR", ~c"1"}
    ]
  end

  # stdin comes from a file (see `write_request_files/2`); stderr goes to a second
  # file rather than being merged into stdout, because stdout is a
  # newline-delimited JSON channel and an interleaved diagnostic would corrupt
  # whichever event it landed in the middle of. Reading it after exit costs
  # nothing and is the only explanation available when the CLI dies early.
  @shell_script ~S(exec "$0" "$@" < "$OSA_CLAUDE_STDIN" 2> "$OSA_CLAUDE_STDERR")

  defp spawn_and_collect(sh, args, stdin_path, callback, timeout_ms) do
    stderr_path = stdin_path <> ".err"

    port =
      Port.open({:spawn_executable, sh}, [
        :binary,
        :exit_status,
        :hide,
        # `-c SCRIPT NAME ARG…` — NAME becomes `$0` and the rest `$@`, so the
        # binary path and its flags are positional parameters the shell never
        # re-parses. Nothing user-supplied is interpolated into the script.
        {:args, ["-c", @shell_script | args]},
        # The CLI is a trusted binary, but it is still a child that would
        # otherwise inherit OPENAI_API_KEY, gateway tokens and every other
        # provider credential. Scrub first; `child_env/2` is applied on top, so
        # its own deliberate overrides (and the stdin/stderr paths) win.
        {:env, OptimalSystemAgent.OS.Env.port_env(child_env(stdin_path, stderr_path))}
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      collect(port, deadline, callback, %{
        buffer: "",
        # `text` is assembled from the CLI's `assistant` events and is
        # authoritative. `stream_text` is the concatenation of partial deltas
        # and exists ONLY to drive incremental display. Keeping them apart is
        # not fussiness: with `--include-partial-messages` the same tokens
        # arrive twice, and appending both is how a streamed reply ends up
        # duplicated in the transcript.
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

      # Not JSON: the CLI wrote a human-readable diagnostic (an update notice,
      # a crash). Keep it — it is the only explanation the user will get if
      # the process then exits non-zero.
      _ ->
        case String.trim(line) do
          "" -> acc
          other -> %{acc | stderr: acc.stderr <> other <> "\n"}
        end
    end
  end

  defp handle_event(%{"type" => "stream_event", "event" => event}, acc, callback) do
    stream_event(event, acc, callback)
  end

  defp handle_event(%{"type" => "assistant", "message" => message}, acc, _callback) do
    # The assembled turn. Authoritative for the final content, so partial
    # deltas are only ever used for display.
    remember_model(message)
    %{acc | text: acc.text <> text_of(message)}
  end

  defp handle_event(%{"type" => "result"} = result, acc, _callback) do
    remember_usage(result)

    if result["is_error"] == true do
      %{acc | error: result_error(result)}
    else
      # `result` carries the final text too; prefer the accumulated assistant
      # turns when present so multi-block content is not flattened.
      if acc.text == "" and acc.stream_text == "" and is_binary(result["result"]),
        do: %{acc | text: result["result"]},
        else: acc
    end
  end

  defp handle_event(_other, acc, _callback), do: acc

  defp stream_event(%{"type" => "message_start", "message" => message}, acc, _cb) do
    remember_model(message)
    acc
  end

  defp stream_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}},
         acc,
         callback
       )
       when is_binary(text) do
    emit_text(text, acc, callback)
  end

  defp stream_event(_event, acc, _callback), do: acc

  # Streaming with a text tool-call protocol needs one guard the native path
  # does not: the moment the model starts emitting `<tool_call>`, that text is
  # protocol, not prose, and must not reach the transcript. Emission is
  # therefore lagged by the marker's length so a marker split across two
  # deltas is still caught before any of it is shown.
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

  # Emit whatever the marker-lag held back, once the turn is over and no tool
  # call appeared. Without this the last few characters of every streamed
  # reply arrive only in `{:done, …}`, which reads as a truncated answer that
  # silently completes itself.
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

  defp finish(%{error: error}, _status) when not is_nil(error), do: {:error, error}

  defp finish(acc, 0) do
    raw = if acc.text == "", do: acc.stream_text, else: acc.text

    {:ok,
     %{
       content: clean(raw),
       tool_calls: parse_tool_calls(raw),
       usage: reported_usage(),
       provider_cost_usd: reported_cost()
     }}
  end

  defp finish(acc, status) do
    diagnostics =
      [acc.stderr, read_stderr(acc)]
      |> Enum.map_join("\n", &String.trim/1)
      |> String.trim()
      |> truncate(600)

    {:error, {:cli_exit, status, diagnostics}}
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

  defp parse_tool_calls(text) do
    # Pinned to the hermes dialect rather than auto-detect: OSA asked for this
    # exact markup in the system prompt, so trying six other parsers could
    # only ever produce a false positive from ordinary prose.
    ToolCallParsers.parse(text, "hermes")
  end

  # Strip the protocol markup out of what the user sees. The parsed calls
  # carry the same information structurally.
  defp clean(text) do
    text
    |> String.replace(~r{<tool_call>.*?</tool_call>}s, "")
    |> String.trim()
  end

  defp remember_usage(result) do
    usage = %{
      "usage" => result["usage"],
      "total_cost_usd" => result["total_cost_usd"],
      "duration_ms" => result["duration_ms"],
      "num_turns" => result["num_turns"]
    }

    :persistent_term.put({__MODULE__, :usage}, usage)
    report_usage(usage)
  end

  # ── Usage: written since this provider shipped, read by nothing ───────────
  #
  # `remember_usage/1` above has recorded a full usage map — input, output, both
  # cache slices, AND the CLI's OWN `total_cost_usd`, which is the authoritative
  # figure for a Max-plan account rather than an OSA-side estimate — on every
  # turn since this provider shipped. `last_usage/0` is its only reader, and
  # nothing in `lib/` calls `last_usage/0`. Meanwhile `chat/2` reconstructed its
  # return value from two keys and discarded the rest, so the agent loop never
  # saw a token count from this provider at all.
  #
  # The consequence is the one `Accounting.report_unaccounted/2` was written for
  # and could not detect here: every claude_cli turn normalises to zero tokens
  # and $0.00, `max_budget_usd` is unenforceable, and `$/task` reads 0 — on the
  # provider the operator actually runs on.
  #
  # `:claude_cli` already sits in `Accounting`'s `@disjoint_prompt_slices`, i.e.
  # the billing convention was configured for a usage map that never arrived.
  #
  # The KEY NAMES are the contract: `Loop.Accounting.normalize_usage/1` reads
  # exactly `:input_tokens`, `:output_tokens`, `:cache_creation_input_tokens`
  # and `:cache_read_input_tokens`. The CLI happens to emit Anthropic's own
  # names, so this is a rename into atoms, not arithmetic.
  @doc """
  The last turn's usage in the four key names `Loop.Accounting.normalize_usage/1`
  reads, or `nil` when the CLI reported none.

  Public because it is the contract with the accounting layer, and because
  `last_usage/0` — the raw CLI map — proved to be a shape nothing was willing
  to consume.
  """
  @spec reported_usage() :: map() | nil
  def reported_usage do
    case :persistent_term.get({__MODULE__, :usage}, nil) do
      %{"usage" => u} when is_map(u) ->
        %{
          input_tokens: int(u["input_tokens"]),
          output_tokens: int(u["output_tokens"]),
          cache_creation_input_tokens: int(u["cache_creation_input_tokens"]),
          cache_read_input_tokens: int(u["cache_read_input_tokens"])
        }

      _ ->
        nil
    end
  end

  @doc """
  The CLI's own `total_cost_usd` for the last turn, or `nil`.

  Published as a SEPARATE key from `:usage` on purpose. It is not a token
  count and must not be priced from OSA's rate card: on a Max-plan account the
  marginal cost of a turn is not `tokens × list price`, and the CLI is the only
  party that knows which it was. A consumer that has this number should prefer
  it over anything derived from `:usage`.
  """
  @spec reported_cost() :: float() | nil
  def reported_cost do
    case :persistent_term.get({__MODULE__, :usage}, nil) do
      %{"total_cost_usd" => c} when is_float(c) -> c
      %{"total_cost_usd" => c} when is_integer(c) -> c * 1.0
      _ -> nil
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  defp report_usage(usage) do
    u = usage["usage"] || %{}

    :telemetry.execute(
      [:osa, :cli_provider, :usage],
      %{
        input_tokens: int(u["input_tokens"]),
        output_tokens: int(u["output_tokens"]),
        cache_read_input_tokens: int(u["cache_read_input_tokens"]),
        cache_creation_input_tokens: int(u["cache_creation_input_tokens"]),
        total_cost_usd: usage["total_cost_usd"] || 0
      },
      %{provider: :claude_cli, model: last_resolved_model()}
    )

    # A CLI turn that reported NO usage is the one worth a line: it is
    # indistinguishable from a free turn, and that is exactly how this provider
    # billed $0.00 for its whole life.
    if u == %{} or map_size(u) == 0 do
      if Process.get(:osa_claude_cli_unaccounted) != true do
        Process.put(:osa_claude_cli_unaccounted, true)

        Logger.warning(
          "[claude_cli] the CLI reported no token usage for this turn — it will account as " <>
            "0 tokens and $0.00, and max_budget_usd cannot be enforced against it."
        )
      end
    end

    :ok
  end

  defp result_error(result) do
    {:cli_api_error, result["api_error_status"], to_string(result["result"] || "")}
  end

  # The concrete model an alias resolved to, straight from the CLI. Recorded
  # rather than guessed — a status line that names a model OSA is not running
  # is a bug this codebase has shipped before.
  defp remember_model(%{"model" => model}) when is_binary(model) and model != "" do
    if model != "<synthetic>", do: :persistent_term.put({__MODULE__, :resolved_model}, model)
    :ok
  end

  defp remember_model(_), do: :ok

  defp text_of(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("", &to_string(&1["text"] || ""))
  end

  defp text_of(_), do: ""

  # ── Prompt assembly ─────────────────────────────────────────────────────

  @doc false
  @spec split_system(list()) :: {String.t(), list()}
  def split_system(messages) do
    {system, rest} =
      Enum.split_with(messages, fn m -> to_string(role_of(m)) == "system" end)

    {system |> Enum.map_join("\n\n", &to_string(content_of(&1) || "")) |> String.trim(), rest}
  end

  @doc """
  The system prompt handed to the CLI: OSA's own, plus a tool protocol section
  when OSA has tools to offer.

  Public because it is the piece most worth asserting on directly — a change
  that silently drops the tool section turns this provider into a chat-only
  one, and that should fail a test rather than a user's turn.
  """
  @spec build_system_prompt(String.t(), list()) :: String.t()
  def build_system_prompt(system, tools) do
    base = if system == "", do: "You are OSA, a helpful coding agent.", else: system

    case tools do
      [] -> base
      list when is_list(list) -> base <> "\n\n" <> tool_protocol(list)
      _ -> base
    end
  end

  @doc false
  @spec tool_protocol(list()) :: String.t()
  def tool_protocol(tools) do
    specs =
      Enum.map_join(tools, "\n\n", fn tool ->
        name = to_string(get(tool, :name) || "")
        desc = to_string(get(tool, :description) || "")
        params = get(tool, :parameters) || %{}

        "### #{name}\n#{desc}\nJSON Schema for `arguments`:\n" <>
          (Jason.encode(params) |> ok_or("{}"))
      end)

    """
    ## Tool calls

    You have tools. To call one, emit a line containing exactly:

    <tool_call>{"name": "<tool name>", "arguments": { ... }}</tool_call>

    Rules:
    - Emit the tag verbatim; `arguments` must be valid JSON matching the tool's schema.
    - One `<tool_call>` block per call. Multiple blocks are allowed in one reply.
    - Do not describe a call you are also emitting; the caller runs it and returns the result.
    - If no tool is needed, answer normally and emit no tag.

    ## Available tools

    #{specs}
    """
  end

  defp ok_or({:ok, v}, _default), do: v
  defp ok_or(_, default), do: default

  @doc """
  Flatten OSA's conversation into the single user turn the CLI accepts.

  `claude -p` takes user input only — there is no way to replay assistant
  turns into a fresh session, and the alternative (`--resume` against a stored
  session) is precisely the design that leaves the two histories able to
  disagree, which is the documented failure of the existing Pi bridges. A
  flattened transcript is a real fidelity cost — the model reads its own past
  replies as quoted text rather than as its own turns — but it is honest about
  what it is, it is stateless, and OSA's history stays the only history.
  """
  @spec render_turns(list()) :: String.t()
  def render_turns([]), do: ""

  def render_turns(turns) do
    {history, [last]} = Enum.split(turns, -1)

    case history do
      [] ->
        to_string(content_of(last) || "")

      _ ->
        transcript = Enum.map_join(history, "\n\n", &render_turn/1)

        """
        Here is the conversation so far, for context:

        <transcript>
        #{transcript}
        </transcript>

        Now respond to this latest message:

        #{to_string(content_of(last) || "")}
        """
    end
  end

  defp render_turn(message) do
    role = to_string(role_of(message))
    content = to_string(content_of(message) || "")

    case role do
      "assistant" -> "[assistant]\n#{content}"
      "tool" -> "[tool result#{tool_name_suffix(message)}]\n#{content}"
      _ -> "[user]\n#{content}"
    end
  end

  defp tool_name_suffix(message) do
    case get(message, :name) do
      n when is_binary(n) and n != "" -> " from #{n}"
      _ -> ""
    end
  end

  defp stream_json_user(text) do
    Jason.encode!(%{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
    }) <> "\n"
  end

  # ── request files ───────────────────────────────────────────────────────

  # The conversation and the system prompt are written to private files
  # rather than passed on the command line — the prompt because argv would
  # both publish it via `ps` and hit MAX_ARG_STRLEN (see `cli_args/4`). The
  # directory is created 0700 before any file exists, so there is no window
  # in which the default umask exposes them — the same from-birth rule
  # `SubscriptionStore` follows for tokens, applied here because a prompt can
  # carry just as much of the user's private code.
  defp write_request_files(stdin_line, system_prompt) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "osa-claude-#{System.system_time(:nanosecond)}-#{:erlang.unique_integer([:positive])}"
      )

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         file = Path.join(dir, "input.jsonl"),
         :ok <- File.write(file, stdin_line),
         :ok <- File.chmod(file, 0o600),
         prompt_file = Path.join(dir, "system_prompt.md"),
         :ok <- File.write(prompt_file, system_prompt),
         :ok <- File.chmod(prompt_file, 0o600) do
      {:ok, dir, file, prompt_file}
    else
      {:error, reason} ->
        File.rm_rf(dir)
        {:error, {:tmp_write_failed, reason}}
    end
  end

  # ── errors ──────────────────────────────────────────────────────────────

  @doc false
  @spec error_message(term()) :: String.t()
  def error_message(:cli_not_installed),
    do:
      "Claude Code is not installed (or not on PATH), so OSA cannot use your Claude subscription. " <>
        "Install it from https://claude.com/product/claude-code, or set OSA_CLAUDE_CLI_BIN to its path. " <>
        "You can also use the `anthropic` provider with an API key."

  def error_message(:no_shell),
    do:
      "OSA could not find a POSIX shell to launch Claude Code with. This is a broken environment."

  def error_message(:timeout),
    do:
      "Claude Code did not finish in time. Long turns can be extended with " <>
        "config `:claude_cli_timeout_ms`."

  def error_message({:cli_api_error, status, detail}) do
    base = "Claude Code reported an API error"
    base = if status, do: base <> " (HTTP #{status})", else: base
    if detail == "", do: base <> ".", else: base <> ": " <> detail
  end

  # Exit status 7 with silent stderr is almost always not the CLI at all:
  # execve failed with E2BIG (errno 7, "argument list too long") because an
  # argv element crossed Linux's 128KiB MAX_ARG_STRLEN, and the Erlang port
  # forker reports the errno as the exit status. `cli_args/4` no longer puts
  # anything unbounded on argv, so this should be historical — but if it
  # fires, say what it means instead of sending the user to auth.
  def error_message({:cli_exit, 7, ""}),
    do:
      "Claude Code could not be launched: a command-line argument exceeded the OS limit " <>
        "(E2BIG, errno 7). This is an OSA bug — the request never reached Claude. " <>
        "Please report it with the session that triggered it."

  def error_message({:cli_exit, status, ""}),
    do:
      "Claude Code exited with status #{status} and said nothing. Run `claude auth status` to check your sign-in."

  def error_message({:cli_exit, status, detail}),
    do: "Claude Code exited with status #{status}: #{detail}"

  def error_message({:tmp_write_failed, reason}),
    do: "Could not write a private temporary file for the request: #{inspect(reason)}"

  def error_message(other), do: "Claude Code bridge failed: #{inspect(other)}"

  # ── message accessors (maps with either atom or string keys) ────────────

  defp role_of(m), do: get(m, :role) || "user"
  defp content_of(m), do: get(m, :content)

  defp get(m, key) when is_map(m) do
    Map.get(m, key) || Map.get(m, to_string(key))
  end

  defp get(_, _), do: nil
end
