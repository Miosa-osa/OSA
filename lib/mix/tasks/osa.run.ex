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
  - `--effort` — Effort level: low, medium, high, max
  - `--resume` — Resume a previous session by ID
  """
  use Mix.Task

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
          resume: :string
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

    # Set effort level if specified
    if effort = opts[:effort] do
      OptimalSystemAgent.Agent.Effort.set(String.to_atom(effort))
    end

    # Create session
    session_id = opts[:resume] || "headless_#{System.unique_integer([:positive])}"

    loop_opts =
      [
        session_id: session_id,
        channel: :headless,
        model: opts[:model],
        provider: if(opts[:provider], do: String.to_atom(opts[:provider])),
        max_turns: opts[:max_turns],
        max_budget_usd: opts[:max_budget]
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
        IO.puts(response)

      {"text", {:error, reason}} ->
        IO.puts(:stderr, "Error: #{reason}")
        System.halt(1)

      {"json", {:ok, response}} ->
        output = %{
          type: "result",
          session_id: session_id,
          content: response,
          model: opts[:model] || Application.get_env(:optimal_system_agent, :default_provider),
          cost: get_session_cost()
        }

        IO.puts(Jason.encode!(output))

      {"json", {:error, reason}} ->
        output = %{type: "error", session_id: session_id, error: to_string(reason)}
        IO.puts(Jason.encode!(output))
        System.halt(1)

      {"stream-json", {:ok, response}} ->
        # Final result event
        IO.puts(Jason.encode!(%{type: "result", content: response}))

      {"stream-json", {:error, reason}} ->
        IO.puts(Jason.encode!(%{type: "error", error: to_string(reason)}))
        System.halt(1)

      _ ->
        IO.puts(:stderr, "Unknown format: #{format}")
        System.halt(1)
    end
  end

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
            IO.puts(Jason.encode!(%{type: "token", delta: Map.get(payload, :delta)}))

          :thinking_delta ->
            IO.puts(Jason.encode!(%{type: "thinking", delta: Map.get(payload, :delta)}))

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
          Jason.encode!(%{
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
