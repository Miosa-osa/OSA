defmodule OptimalSystemAgent.Healing.EphemeralAgent do
  @moduledoc """
  Short-lived repair agent that runs a single LLM call for healing purposes.

  Each instance handles exactly one role — `:diagnostician` or `:fixer` — then
  terminates normally. The parent orchestrator monitors it via `Process.monitor/1`
  and handles the result message.

  ## Lifecycle

  1. `start_link/1` — spawns the GenServer
  2. `init/1` — schedules an immediate `:run` via `handle_continue`
  3. `handle_continue(:run, ...)` — executes the LLM call
  4. On success: sends result to parent, then stops with `:normal`
  5. On failure or budget breach: sends error to parent, then stops with `:normal`

  The parent always receives either `{:diagnosis, result}` or `{:fix_applied, result}`
  (success), or `{:ephemeral_error, role, reason}` (failure).

  ## Messages sent to parent_pid

      {:diagnosis, %{root_cause: ..., confidence: ..., ...}}
      {:fix_applied, %{fix_applied: ..., description: ..., file_changes: ..., ...}}
      {:ephemeral_error, role, reason}
  """

  use GenServer
  require Logger

  alias OptimalSystemAgent.Healing.Prompts
  alias OptimalSystemAgent.Providers.Registry, as: Providers

  @default_timeout_ms 120_000
  @json_extract_pattern ~r/\{[\s\S]*\}/

  # -- Client API --

  @doc """
  Start an ephemeral repair agent.

  Required opts:
  - `:role` — `:diagnostician` or `:fixer`
  - `:context` — error context map (see `Prompts.diagnostic_prompt/1`)
  - `:parent_pid` — PID to send results/errors to

  Optional opts:
  - `:budget_usd` — max spend for this agent (default: 0.50)
  - `:diagnosis` — required when role is `:fixer`
  - `:provider` — override provider atom
  - `:model` — override model string
  - `:timeout_ms` — max time before self-termination (default: 120_000ms)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    role = Keyword.fetch!(opts, :role)
    context = Keyword.fetch!(opts, :context)
    parent_pid = Keyword.fetch!(opts, :parent_pid)

    state = %{
      role: role,
      context: context,
      parent_pid: parent_pid,
      diagnosis: Keyword.get(opts, :diagnosis),
      budget_usd: Keyword.get(opts, :budget_usd, 0.50),
      spent_usd: 0.0,
      provider: Keyword.get(opts, :provider),
      model: Keyword.get(opts, :model),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    }

    Logger.info("[EphemeralAgent] Starting #{role} agent (parent: #{inspect(parent_pid)})")

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    # Arm a self-destruct timer in case the LLM call hangs
    Process.send_after(self(), :timeout, state.timeout_ms)

    result = execute(state)

    case result do
      {:ok, parsed} ->
        send_result(state.role, parsed, state.parent_pid)

      {:error, reason} ->
        Logger.warning("[EphemeralAgent] #{state.role} failed: #{inspect(reason)}")
        send(state.parent_pid, {:ephemeral_error, self(), state.role, reason})
    end

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.warning("[EphemeralAgent] #{state.role} timed out after #{state.timeout_ms}ms")
    send(state.parent_pid, {:ephemeral_error, self(), state.role, :timeout})
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp execute(%{role: :diagnostician} = state) do
    prompt = Prompts.diagnostic_prompt(state.context)
    call_llm_and_parse(prompt, state)
  end

  defp execute(%{role: :fixer, diagnosis: diagnosis} = state) when not is_nil(diagnosis) do
    prompt = Prompts.fix_prompt(diagnosis, state.context)
    call_llm_and_parse(prompt, state)
  end

  defp execute(%{role: :fixer}) do
    {:error, :missing_diagnosis}
  end

  defp call_llm_and_parse(prompt, state) do
    if state.spent_usd >= state.budget_usd do
      {:error, :budget_exceeded}
    else
      messages = [%{role: "user", content: prompt}]

      opts =
        []
        |> maybe_put(:provider, state.provider)
        |> maybe_put(:model, state.model)

      case Providers.chat(messages, opts) do
        {:ok, response} ->
          content = extract_content(response)
          cost = estimate_cost(response)

          if state.spent_usd + cost > state.budget_usd do
            Logger.warning("[EphemeralAgent] Budget exceeded mid-call — cost: $#{cost}")
          end

          parse_json_response(content)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp send_result(:diagnostician, parsed, parent_pid) do
    send(parent_pid, {:diagnosis, self(), parsed})
  end

  defp send_result(:fixer, parsed, parent_pid) do
    send(parent_pid, {:fix_applied, self(), parsed})
  end

  defp parse_json_response(content) when is_binary(content) do
    # Extract JSON object from response — models sometimes add preamble text
    case Regex.run(@json_extract_pattern, content) do
      [json_str | _] ->
        case Jason.decode(json_str) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, {:json_parse_failed, content}}
        end

      nil ->
        {:error, {:no_json_in_response, content}}
    end
  end

  defp parse_json_response(_content), do: {:error, :empty_response}

  defp extract_content(%{content: content}) when is_binary(content), do: content
  defp extract_content(%{"content" => content}) when is_binary(content), do: content
  defp extract_content(%{text: text}) when is_binary(text), do: text
  defp extract_content(%{"text" => text}) when is_binary(text), do: text
  defp extract_content(other), do: inspect(other)

  defp estimate_cost(%{usage: %{input_tokens: i, output_tokens: o}}) do
    # Conservative default rate estimate — actual cost tracked by Budget GenServer
    (i + o) / 1_000_000 * 4.0
  end

  defp estimate_cost(_), do: 0.0

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
