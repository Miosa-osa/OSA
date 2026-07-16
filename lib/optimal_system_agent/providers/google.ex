defmodule OptimalSystemAgent.Providers.Google do
  @moduledoc """
  Google Gemini provider.

  Uses the Generative Language API (generateContent). API key is passed
  as a query parameter. Handles multi-part content blocks and function
  calling via Google's tool declaration format.

  Config keys:
    :google_api_key — required (GOOGLE_API_KEY / GEMINI_API_KEY)
    :google_model   — (default: gemini-2.0-flash)
    :google_url     — override base URL
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  @default_url "https://generativelanguage.googleapis.com/v1beta"

  @impl true
  def name, do: :google

  @impl true
  def default_model, do: "gemini-2.0-flash"

  @impl true
  def available_models do
    ["gemini-2.0-flash", "gemini-2.5-pro", "gemini-2.5-flash"]
  end

  @impl true
  def chat(messages, opts \\ []) do
    api_key = Application.get_env(:optimal_system_agent, :google_api_key)

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :google_model, default_model())

    base_url = Application.get_env(:optimal_system_agent, :google_url, @default_url)

    unless api_key do
      {:error, "GOOGLE_API_KEY not configured"}
    else
      do_chat(base_url, api_key, model, messages, opts)
    end
  end

  defp do_chat(base_url, api_key, model, messages, opts) do
    formatted = format_messages(messages)
    {system_instruction, contents} = extract_system(formatted)

    body =
      %{contents: contents}
      |> maybe_add_system_instruction(system_instruction)
      |> maybe_add_generation_config(model, opts)
      |> maybe_add_tools(opts)

    url = "#{base_url}/models/#{model}:generateContent?key=#{api_key}"
    headers = [{"Content-Type", "application/json"}]
    # Gemini 2.5 thinking models can take 300+ s for complex reasoning
    timeout = if thinking_model?(model), do: 600_000, else: 120_000

    try do
      case Req.post(url, json: body, headers: headers, receive_timeout: timeout) do
        {:ok, %{status: 200, body: resp}} ->
          content = extract_content(resp)
          tool_calls = extract_tool_calls(resp)
          {:ok, %{content: content, tool_calls: tool_calls, usage: extract_usage(resp)}}

        {:ok, %{status: status, body: resp_body}} ->
          error_msg = extract_error(resp_body)
          Logger.warning("Google Gemini returned #{status}: #{error_msg}")
          {:error, "Google Gemini returned #{status}: #{error_msg}"}

        {:error, reason} ->
          Logger.error("Google Gemini connection failed: #{inspect(reason)}")
          {:error, "Google Gemini connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Google Gemini unexpected error: #{Exception.message(e)}")
        {:error, "Google Gemini unexpected error: #{Exception.message(e)}"}
    end
  end

  # --- Private ---

  defp format_messages(messages) do
    Enum.map(messages, fn
      %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => to_string(content)}

      %{"role" => _} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end)
  end

  defp extract_system(messages) do
    {sys_msgs, chat_msgs} = Enum.split_with(messages, &(&1["role"] == "system"))

    system_text =
      case sys_msgs do
        [] -> nil
        msgs -> Enum.map_join(msgs, "\n\n", & &1["content"])
      end

    # Google uses "user" and "model" roles (not "assistant")
    contents =
      Enum.map(chat_msgs, fn msg ->
        gemini_role =
          case msg["role"] do
            "assistant" -> "model"
            role -> role
          end

        %{
          "role" => gemini_role,
          "parts" => [%{"text" => msg["content"] || ""}]
        }
      end)

    {system_text, contents}
  end

  defp maybe_add_system_instruction(body, nil), do: body
  defp maybe_add_system_instruction(body, ""), do: body

  defp maybe_add_system_instruction(body, text) do
    Map.put(body, :systemInstruction, %{
      "parts" => [%{"text" => text}]
    })
  end

  defp maybe_add_generation_config(body, model, opts) do
    config =
      %{}
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))
      |> maybe_put(:maxOutputTokens, Keyword.get(opts, :max_tokens))
      |> maybe_add_thinking_config(model, opts)

    if map_size(config) > 0 do
      Map.put(body, :generationConfig, config)
    else
      body
    end
  end

  # Gemini 2.5 Pro/Flash support thinkingConfig for extended reasoning.
  # Default: enabled with 8192 token budget for thinking models.
  # Override per-call: opts[:thinking_budget] = N (0 to disable).
  defp maybe_add_thinking_config(config, model, opts) do
    if thinking_model?(model) do
      budget = Keyword.get(opts, :thinking_budget, 8192)

      if budget > 0 do
        Map.put(config, :thinkingConfig, %{thinkingBudget: budget})
      else
        config
      end
    else
      config
    end
  end

  # Gemini 2.5 models support extended thinking
  defp thinking_model?(model_name) do
    name = String.downcase(to_string(model_name))
    String.contains?(name, "2.5")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools -> Map.put(body, :tools, [%{"functionDeclarations" => format_tools(tools)}])
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }
    end)
  end

  defp extract_content(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parts
    |> Enum.filter(&Map.has_key?(&1, "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp extract_content(_), do: ""

  defp extract_tool_calls(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    parts
    |> Enum.filter(&Map.has_key?(&1, "functionCall"))
    |> Enum.map(fn part ->
      fc = part["functionCall"]

      %{
        id: generate_id(),
        name: fc["name"],
        arguments: fc["args"] || %{}
      }
    end)
  end

  defp extract_tool_calls(_), do: []

  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(%{"error" => msg}) when is_binary(msg), do: msg
  defp extract_error(body), do: inspect(body)

  # Extract token usage from Gemini's usageMetadata so Accounting/Pricing record
  # real spend. Without this every Gemini turn recorded 0 tokens / $0, leaving
  # the hard budget cap permanently blind on Google.
  defp extract_usage(%{"usageMetadata" => meta}) when is_map(meta) do
    %{
      input_tokens: meta["promptTokenCount"] || 0,
      output_tokens: meta["candidatesTokenCount"] || 0
    }
  end

  defp extract_usage(_), do: %{}

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
