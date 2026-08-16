defmodule OptimalSystemAgent.Providers.Replicate do

  alias OptimalSystemAgent.Providers.ConfiguredModel
  @moduledoc """
  Replicate provider — run open-source models via prediction API.

  Replicate uses a prediction-based (async poll) API, not OpenAI-compatible.
  This module creates a prediction and polls until it succeeds or fails.

  API flow:
    1. POST /v1/predictions  → {id, status: "starting"}
    2. GET  /v1/predictions/:id  → poll until status is "succeeded" or "failed"

  Config keys:
    :replicate_api_key — required (REPLICATE_API_KEY)
    :replicate_model   — (default: openai/gpt-oss-120b)
    :replicate_url     — override base URL

  ## Replicate publishes no context windows

  Unlike every other provider OSA supports, Replicate exposes **no
  machine-readable context window** anywhere: the model object's
  `openapi_schema` describes *input parameters* only (`prompt`, `max_tokens`,
  `seed`), and the model pages state context only as marketing prose inside
  benchmark blurbs. So `Catalog`/`ModelLimits` can never learn a Replicate
  window from Replicate.

  The consequence is deliberate and documented in `available_models/0`: OSA
  offers only slugs whose window is published by the model's ORIGINAL vendor
  (OpenAI for `gpt-oss-*`, Anthropic for `anthropic/*`), and takes the number
  from there. A slug whose window exists nowhere authoritative is not offered
  at all rather than budgeted with a guess.
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  @default_url "https://api.replicate.com/v1"
  @poll_interval_ms 1_000
  @max_polls 120

  @impl true
  def name, do: :replicate

  # `meta/llama-3.3-70b-instruct` was the default AND all three tier entries,
  # and it **does not exist on Replicate** — https://replicate.com/meta/llama-3.3-70b-instruct
  # returns a hard 404 (verified 2026-08-01). Replicate skipped Llama 3.3 on
  # the official `meta/*` account entirely: it went Llama 3 → Llama 4. Every
  # Replicate request OSA made failed at model resolution.
  #
  # Note the naming trap that helped hide this: Llama 3 slugs carry a DOUBLED
  # prefix (`meta/meta-llama-3-70b-instruct`) while Llama 4 does not
  # (`meta/llama-4-scout-instruct`), so neither convention predicts the other.
  #
  # The replacement is `openai/gpt-oss-120b` — verified 200 on Replicate, and
  # its 131,072 window is published by OpenAI for the open-weight model itself
  # (and independently agreed by Groq, Cerebras and Fireworks), so OSA can
  # budget it honestly despite Replicate publishing nothing.
  @impl true
  def default_model, do: "openai/gpt-oss-120b"

  @doc """
  Slugs OSA offers on Replicate.

  Every entry is verified to resolve (HTTP 200 on its model page) AND to have a
  context window published by the model's original vendor — see the moduledoc
  for why that second condition is non-negotiable here.
  """
  @impl true
  def available_models do
    [
      "openai/gpt-oss-120b",
      "openai/gpt-oss-20b",
      "anthropic/claude-opus-4.6"
    ]
  end

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :replicate_api_key)

    model =
      ConfiguredModel.resolve(opts, :replicate, &default_model/0)

    base_url = Application.get_env(:optimal_system_agent, :replicate_url, @default_url)

    unless api_key do
      {:error, "REPLICATE_API_KEY not configured"}
    else
      do_chat(base_url, api_key, model, messages, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    {system_prompt, user_prompt} = build_prompt(messages)

    input =
      %{
        prompt: user_prompt,
        max_tokens: Keyword.get(opts, :max_tokens, 2048)
      }
      |> maybe_add_system(system_prompt)

    body = %{model: model, input: input}
    headers = [{"Authorization", "Bearer #{api_key}"}, {"Content-Type", "application/json"}]

    try do
      case Req.post("#{base_url}/predictions",
             json: body,
             headers: headers,
             receive_timeout: 30_000
           ) do
        {:ok, %{status: status, body: %{"id" => prediction_id}}} when status in [200, 201] ->
          poll_prediction(base_url, api_key, prediction_id, headers, 0)

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("Replicate create prediction returned #{status}: #{inspect(resp_body)}")
          {:error, "Replicate returned #{status}: #{inspect(resp_body)}"}

        {:error, reason} ->
          Logger.error("Replicate connection failed: #{inspect(reason)}")
          {:error, "Replicate connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Replicate unexpected error: #{Exception.message(e)}")
        {:error, "Replicate unexpected error: #{Exception.message(e)}"}
    end
  end

  defp poll_prediction(_base_url, _api_key, _id, _headers, polls)
       when polls >= @max_polls do
    {:error, "Replicate prediction timed out after #{@max_polls} polls"}
  end

  defp poll_prediction(base_url, api_key, id, headers, polls) do
    Process.sleep(@poll_interval_ms)

    case Req.get("#{base_url}/predictions/#{id}",
           headers: headers,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"status" => "succeeded", "output" => output}}} ->
        content = parse_output(output)
        {:ok, %{content: content, tool_calls: []}}

      {:ok, %{status: 200, body: %{"status" => "failed", "error" => error}}} ->
        {:error, "Replicate prediction failed: #{error}"}

      {:ok, %{status: 200, body: %{"status" => status}}}
      when status in ["starting", "processing"] ->
        Logger.debug("Replicate prediction #{id} status: #{status} (poll #{polls + 1})")
        poll_prediction(base_url, api_key, id, headers, polls + 1)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "Replicate poll returned #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        {:error, "Replicate poll connection failed: #{inspect(reason)}"}
    end
  end

  # --- Private ---

  defp build_prompt(messages) do
    formatted =
      Enum.map(messages, fn
        %{role: role, content: content} ->
          %{"role" => to_string(role), "content" => to_string(content)}

        %{"role" => _} = msg ->
          msg

        msg when is_map(msg) ->
          msg
      end)

    # Only LEADING system messages are the system prompt. A system message that
    # appears after the conversation has started is mid-turn steering from
    # `ReactLoop` (it appends `[assistant_text, system_nudge]` and means the
    # nudge to be the last thing the model reads), so hoisting it into
    # `system_prompt` would bury a directive in background context. Same defect
    # as Providers.Google; here it degrades silently too, since the transcript is
    # flattened into a prompt string. Mid-turn system messages stay in place,
    # rendered as `User:` lines so they read as input to act on.
    {leading, rest} = Enum.split_while(formatted, &(&1["role"] == "system"))

    system_text = Enum.map_join(leading, "\n\n", & &1["content"])

    conversation =
      Enum.map_join(rest, "\n", fn msg ->
        role = String.capitalize(if msg["role"] in [nil, "system"], do: "user", else: msg["role"])
        "#{role}: #{msg["content"]}"
      end)

    {system_text, conversation <> "\nAssistant:"}
  end

  defp maybe_add_system(input, ""), do: input
  defp maybe_add_system(input, nil), do: input
  defp maybe_add_system(input, system_prompt), do: Map.put(input, :system_prompt, system_prompt)

  defp parse_output(output) when is_list(output), do: Enum.join(output)
  defp parse_output(output) when is_binary(output), do: output
  defp parse_output(_), do: ""
end
