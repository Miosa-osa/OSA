defmodule Mix.Tasks.Osa.Run do
  @moduledoc """
  Non-interactive headless mode — process a single prompt and output result.

  Supports three output formats:
  - `text` (default) — plain text response
  - `json` — structured JSON with metadata
  - `stream-json` — NDJSON stream of events as they happen

  ## Usage

      mix osa.run "Your prompt here"
      mix osa.run --format json "Explain this code"
      echo "Fix the bug" | mix osa.run --format stream-json
      mix osa.run --resume cli_abc123 "Continue where we left off"

  ## Options

  - `--format` / `-f` — Output format: text, json, stream-json (default: text)
  - `--model` / `-m` — Model override
  - `--provider` / `-p` — Provider override
  - `--max-turns` — Maximum conversation turns
  - `--max-budget` — Maximum spend in USD
  - `--effort` — Effort level: fast, medium, high, xhigh, ultra
    (`low` and `max` are accepted as legacy aliases for `fast` and `xhigh`).
    An unrecognised level is a hard error, not a silent fallback — a benchmark
    run that meant to pin effort must not quietly produce an unpinned number.
  - `--resume` — Resume a previous session by ID
  - `--ask-user` — Allow the agent to stop and ask a question. OFF by default,
    here as everywhere else: nothing is attached to a headless run to answer
    one, so an `ask_user` call blocks the turn for its full five-minute timeout
    and then continues on the assumption it would have made anyway. Pass this
    only when a human is actually watching the pipe.

  ## Terminal safety

  `text` is a terminal render, so the response is scrubbed
  (`OptimalSystemAgent.CLI.Sanitize`, block tier — a headless answer is a
  multi-line body). Headless mode is the *most* exposed of the three CLI paths:
  it is what CI and shell pipelines call, so nobody is watching the screen while
  a model-chosen `ESC ] 52 ; c ; … BEL` writes the operator's clipboard.

  The `json` and `stream-json` formats are deliberately NOT scrubbed. They are a
  machine-readable contract and must round-trip the model's bytes exactly; JSON
  string escaping already renders ESC, BEL and CR inert on the way to a terminal
  (`\\u001b`), and `escape: :unicode_safe` extends that to the C1 range, which
  the default escape mode emits literally. The result is ASCII-only output that
  decodes back to precisely the original string — lossless for the consumer,
  inert for the terminal.
  """
  use Mix.Task

  alias OptimalSystemAgent.CLI.Sanitize

  @shortdoc "Run OSA in non-interactive headless mode"

  @impl true
  def run(args) do
    # Suppress boot logs
    Logger.configure(level: :error)

    # Start the application
    Mix.Task.run("app.start", [])

    {opts, positional, _} =
      OptionParser.parse(args,
        switches: [
          format: :string,
          model: :string,
          provider: :string,
          max_turns: :integer,
          max_budget: :float,
          effort: :string,
          resume: :string,
          # Off by default like everywhere else, but the flag exists BECAUSE
          # this is the headless path: there is no channel to answer a question
          # on, so a blocked `ask_user` here stalls until its 5-minute timeout
          # with nobody able to shorten it. `--ask-user` is for the case where a
          # human really is watching a scripted run.
          ask_user: :boolean
        ],
        aliases: [f: :format, m: :model, p: :provider]
      )

    format = Keyword.get(opts, :format, "text")

    # Get prompt from positional args or stdin
    prompt =
      case positional do
        [p | _] -> p
        [] -> read_stdin()
      end

    if prompt == nil or String.trim(prompt) == "" do
      IO.puts(:stderr, "Error: no prompt provided. Usage: mix osa.run \"your prompt\"")
      System.halt(1)
    end

    # Set effort level if specified.
    #
    # This used to be `Effort.set(String.to_atom(effort))` with the result
    # thrown away, which had two defects. `String.to_atom/1` on unvalidated CLI
    # input grows the atom table, and — worse — `set/1` returns
    # `{:error, :invalid_level}` for anything off the ladder, so `--effort xhgih`
    # silently ran at the ambient level. A run that asked to be pinned and was
    # not is exactly the condition that makes its number unquotable, so this
    # fails loudly instead. `set/1` normalizes legacy names itself; passing the
    # string through avoids minting atoms for typos.
    if effort = opts[:effort] do
      case OptimalSystemAgent.Agent.Effort.set(effort) do
        :ok ->
          :ok

        {:error, :invalid_level} ->
          IO.puts(
            :stderr,
            "Error: unknown --effort #{inspect(effort)}. " <>
              "Valid levels: fast, medium, high, xhigh, ultra " <>
              "(legacy aliases: low, max)."
          )

          System.halt(1)
      end
    end

    # Create session.
    #
    # This used to be `opts[:resume] || "headless_#{System.unique_integer/1}"`.
    # `--resume` is still verbatim — reusing that session's artifacts is the whole
    # point of resuming — but the generated arm was a collision. Every `osa`
    # invocation is a fresh BEAM and `System.unique_integer/1` restarts near zero
    # on every boot (measured across five boots on this machine: 2564, 2567, 2566,
    # 390, 10), while the id is the key for `~/.osa/sessions/<id>.json`,
    # `<id>.spend.json` and `<id>.goal.json`. A repeat therefore made a fresh
    # headless run inherit an unrelated session's transcript AND its bill —
    # observed on two of six benchmark runs, and `~/.osa/sessions` still holds
    # `headless_4` / `headless_8` / `headless_67` waiting to be landed on again.
    # `SessionId.generate/1` is time-prefixed, CSPRNG-tailed, and refuses an id
    # that already has artifacts on disk.
    session_id = OptimalSystemAgent.Agent.SessionId.resolve(opts[:resume], "headless")

    loop_opts =
      [
        session_id: session_id,
        channel: :headless,
        model: opts[:model],
        provider: if(opts[:provider], do: String.to_atom(opts[:provider])),
        max_turns: opts[:max_turns],
        max_budget_usd: opts[:max_budget],
        ask_user: opts[:ask_user]
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        OptimalSystemAgent.SessionSupervisor,
        {OptimalSystemAgent.Agent.Loop, loop_opts}
      )

    # Register streaming handler for stream-json format
    if format == "stream-json" do
      register_stream_handler(session_id)
    end

    # Process the message
    result = OptimalSystemAgent.Agent.Loop.process_message(session_id, prompt)

    # Output based on format
    case {format, result} do
      {"text", {:ok, response}} ->
        IO.puts(text_output(response))

      {"text", {:error, reason}} ->
        IO.puts(:stderr, "Error: #{Sanitize.scrub_line(to_string(reason))}")
        System.halt(1)

      {"json", {:ok, response}} ->
        output =
          %{
            type: "result",
            session_id: session_id,
            content: response,
            model: opts[:model] || Application.get_env(:optimal_system_agent, :default_provider),
            cost: get_session_cost()
          }
          |> Map.merge(session_usage(session_id))

        IO.puts(json_line(output))

      {"json", {:error, reason}} ->
        output = %{type: "error", session_id: session_id, error: to_string(reason)}
        IO.puts(json_line(output))
        System.halt(1)

      {"stream-json", {:ok, response}} ->
        # Final result event, now carrying the run's own bill. Without this the
        # ONLY way to cost a headless run was to go behind the documented
        # interface and read `~/.osa/sessions/<id>.spend.json` — which is how the
        # colliding-id contamination got into a published measurement in the
        # first place.
        IO.puts(
          json_line(
            Map.merge(
              %{type: "result", session_id: session_id, content: response},
              session_usage(session_id)
            )
          )
        )

      {"stream-json", {:error, reason}} ->
        IO.puts(json_line(%{type: "error", error: to_string(reason)}))
        System.halt(1)

      _ ->
        IO.puts(:stderr, "Unknown format: #{format}")
        System.halt(1)
    end
  end

  @doc """
  The bytes the `text` format puts on stdout — a terminal render, so scrubbed.
  """
  @spec text_output(term()) :: String.t()
  def text_output(response), do: response |> to_string() |> Sanitize.scrub_block()

  @doc """
  One NDJSON line.

  `escape: :unicode_safe` is the load-bearing part: the default escape mode
  already emits ESC/BEL/CR as `\\u001b` and friends, but passes the C1 range
  (U+0080..U+009F) through literally, and U+009B is a CSI introducer that some
  terminals in UTF-8 mode will act on. Escaping all non-ASCII makes the line
  inert on a terminal while decoding back to exactly the original string, so
  the machine-readable contract is unchanged — which is why the *content* is
  not scrubbed here the way `text_output/1` scrubs it.
  """
  @spec json_line(map()) :: String.t()
  def json_line(map), do: Jason.encode!(map, escape: :unicode_safe)

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      :eof -> nil
      {:error, _} -> nil
      data -> String.trim(data)
    end
  rescue
    _ -> nil
  end

  # `Events.Bus.dispatch_event/1` hands a handler the whole CloudEvent
  # ENVELOPE — `%{type:, id:, time:, source:, session_id:, data: %{...}}` —
  # not the payload that was passed to `Bus.emit/3`. `session_id` is promoted
  # to the envelope, so the `== session_id` guard below passed; every other
  # field the handlers wanted lives one level down under `:data`.
  #
  # The consequence was total and silent: `payload.name` raised `key :name not
  # found`, the Bus logged "Handler crash for tool_call", the event went to
  # the DLQ, and `mix osa.run --format stream-json` — the one output format
  # documented as machine-readable — emitted **no token and no tool event at
  # all**, only the closing `result` line. Confirmed on a live glm-5.2 run
  # that made 5 tool calls and streamed 0 of them.
  defp event_payload(%{data: data}) when is_map(data), do: data
  defp event_payload(payload), do: payload

  defp register_stream_handler(session_id) do
    OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn envelope ->
      payload = event_payload(envelope)

      if Map.get(envelope, :session_id) == session_id do
        case Map.get(payload, :event) do
          :streaming_token ->
            IO.puts(json_line(%{type: "token", delta: Map.get(payload, :delta)}))

          :thinking_delta ->
            IO.puts(json_line(%{type: "thinking", delta: Map.get(payload, :delta)}))

          _ ->
            :ok
        end
      end
    end)

    # Per-round-trip token usage.
    #
    # `stream-json` is documented as the machine-readable format, and it emitted
    # tokens, thinking and (since 695cc38c) tool calls — but never a single usage
    # figure, so it could not answer "what did this cost". The numbers were
    # already on the bus: `ReactLoop` emits `:llm_response` with the provider's
    # real `usage` map for EVERY completed round-trip. Nothing was missing but a
    # subscriber. Same `event_payload/1` unwrapping as the handlers above — the
    # Bus hands over a CloudEvent envelope, not the emitted payload.
    OptimalSystemAgent.Events.Bus.register_handler(:llm_response, fn envelope ->
      payload = event_payload(envelope)

      if Map.get(envelope, :session_id) == session_id do
        case Map.get(payload, :usage) do
          usage when is_map(usage) and map_size(usage) > 0 ->
            IO.puts(
              json_line(%{
                type: "usage",
                model: to_string(Map.get(payload, :model)),
                provider: to_string(Map.get(payload, :provider)),
                duration_ms: Map.get(payload, :duration_ms),
                usage: usage_fields(usage)
              })
            )

          _ ->
            :ok
        end
      end
    end)

    OptimalSystemAgent.Events.Bus.register_handler(:tool_call, fn envelope ->
      payload = event_payload(envelope)

      if Map.get(envelope, :session_id) == session_id do
        # `args` here is `Loop.ToolHint.summarize/1` — a DISPLAY string that
        # clips a shell command at 60 characters and reduces every file tool
        # to its bare path. This handler hand-picks its fields, so it was
        # silently re-introducing that lossiness into the one output format
        # meant to be machine-read. `args_bytes` / `args_hash` (see
        # `Loop.ToolArgMetrics`) are the faithful quantities and ride along.
        IO.puts(
          json_line(%{
            type: "tool_use",
            name: Map.get(payload, :name),
            phase: to_string(Map.get(payload, :phase)),
            args: Map.get(payload, :args),
            args_bytes: Map.get(payload, :args_bytes),
            args_hash: Map.get(payload, :args_hash)
          })
        )
      end
    end)
  end

  # The provider's usage map, with the four counters that decide a bill always
  # present. A missing key here reads as "this provider does not report cache
  # tokens", which is indistinguishable from "there were none" — so they are
  # defaulted to 0 and the raw map is not passed through verbatim.
  defp usage_fields(usage) do
    %{
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      cache_creation_tokens: Map.get(usage, :cache_creation_tokens, 0),
      cache_read_tokens: Map.get(usage, :cache_read_tokens, 0)
    }
  end

  # This run's OWN totals, read from the durable spend sidecar the loop just
  # flushed. Distinct from `get_session_cost/0` below, which is the DAY's spend
  # across every session — a number that cannot answer "what did this task cost".
  #
  # `complete: false` means no sidecar was found. The zeros in that case are a
  # placeholder, not a measurement, so the flag rides along in the output rather
  # than letting a reader publish "$0.00" for an unbilled run.
  defp session_usage(session_id) do
    spend = OptimalSystemAgent.Agent.SessionPersistence.load_spend(session_id)

    %{
      session_cost_usd: spend.cost_usd,
      tree_cost_usd: spend.tree_cost_usd,
      usage: %{
        input_tokens: spend.input_tokens,
        output_tokens: spend.output_tokens,
        cache_creation_tokens: spend.cache_creation_tokens,
        cache_read_tokens: spend.cache_read_tokens
      },
      usage_complete: spend.complete
    }
  rescue
    _ -> %{usage_complete: false}
  end

  defp get_session_cost do
    # Two bugs lived here, and each one alone was enough to make `--format json`
    # always report "cost": 0.
    #
    # `get_status/0` replies `{:ok, status}` — a TUPLE — so `budget[:key]` raised
    # and the rescue swallowed it. And `:total_cost_usd` is not a key it returns;
    # the same dead lookup was already found and fixed in `Loop.Limits`
    # (where it silently disabled the budget cap) and in `Agent.Context`.
    #
    # `daily_spent` is the honest aggregate available here. It is the day's
    # spend, not this invocation's, which is stated rather than papered over —
    # a wrong number reported confidently is worse than a labelled approximation.
    case OptimalSystemAgent.Budget.get_status() do
      {:ok, %{daily_spent: spent}} when is_number(spent) -> spent
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
