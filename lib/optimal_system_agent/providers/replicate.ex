defmodule OptimalSystemAgent.Providers.Replicate do
  @moduledoc """
  Replicate provider — run open-source models via prediction API.

  Replicate uses a prediction-based (async poll) API, not OpenAI-compatible.
  This module creates a prediction and polls until it succeeds or fails.

  API flow:
    1. POST /v1/predictions  → {id, status: "starting"}
    2. GET  /v1/predictions/:id  → poll until status is "succeeded" or "failed"

  Config keys:
    :replicate_api_key — required (REPLICATE_API_KEY)
    :replicate_model   — (default: meta/llama-3.3-70b-instruct)
    :replicate_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  @default_url "https://api.replicate.com/v1"
  @poll_interval_ms 1_000
  @max_polls 120

  @impl true
  def name, do: :replicate

  @impl true
  def default_model, do: "meta/llama-3.3-70b-instruct"

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :replicate_api_key)
    model = Keyword.get(opts, :model) || Application.get_env(:optimal_system_agent, :replicate_model, default_model())
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
        %{role: role, content: content} -> %{"role" => to_string(role), "content" => to_string(content)}
        %{"role" => _} = msg -> msg
        msg when is_map(msg) -> msg
      end)

    system_text =
      formatted
      |> Enum.filter(&(&1["role"] == "system"))
      |> Enum.map_join("\n\n", & &1["content"])

    conversation =
      formatted
      |> Enum.reject(&(&1["role"] == "system"))
      |> Enum.map_join("\n", fn msg ->
        role = String.capitalize(msg["role"] || "user")
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
