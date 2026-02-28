defmodule OptimalSystemAgent.Providers.Ollama do
  @moduledoc """
  Ollama local LLM provider.

  Connects to a locally-running Ollama instance. No API key required.
  Supports tool/function calling for models that expose it.

  At boot, auto-detects the best installed model (prefers larger, tool-capable models).
  Only sends tools to models ≥ 14B parameters to avoid hallucinated tool calls.

  Config keys:
    :ollama_url   — base URL (default: http://localhost:11434)
    :ollama_model — model name (default: auto-detected or llama3.2:latest)
  """

  @behaviour OptimalSystemAgent.Providers.Behaviour

  require Logger

  alias OptimalSystemAgent.Utils.Text

  # Models known to handle tool calling well (name prefix → min size in GB)
  # Include both hyphenated and non-hyphenated variants (glm-4 AND glm4)
  @tool_capable_prefixes ~w(qwen3 qwen2.5 llama3.3 llama3.1 gemma3 glm-4 glm4 mistral mixtral deepseek command-r)

  # Minimum model size (in bytes) to enable tool calling — ~14B params ≈ 8GB on disk
  @tool_min_size 7_000_000_000

  @impl true
  def name, do: :ollama

  @impl true
  def default_model do
    # Return whatever auto-detect found, not a hardcoded small model
    Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")
  end

  @doc """
  Auto-detect the best available Ollama model and set it as the active model.
  Called at application boot when provider is :ollama and no explicit model override.
  Prefers larger, tool-capable models.
  """
  @spec auto_detect_model() :: :ok
  def auto_detect_model do
    explicit = Application.get_env(:optimal_system_agent, :default_model)

    if explicit && explicit != "" do
      Logger.info("[Ollama] Using explicitly configured model: #{explicit}")
      Application.put_env(:optimal_system_agent, :ollama_model, explicit)
      :ok
    else
      url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

      case list_models(url) do
        {:ok, models} ->
          best = pick_best_model(models)

          if best do
            current = Application.get_env(:optimal_system_agent, :ollama_model, default_model())

            if best.name != current do
              Logger.info(
                "[Ollama] Auto-selected model: #{best.name} (#{Float.round(best.size / 1.0e9, 1)} GB)"
              )

              Application.put_env(:optimal_system_agent, :ollama_model, best.name)
            end
          end

          :ok

        {:error, _} ->
          :ok
      end
    end
  end

  @doc "List models available on the Ollama server."
  @spec list_models(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_models(url \\ nil) do
    url = url || Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case Req.get("#{url}/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        parsed =
          Enum.map(models, fn m ->
            %{name: m["name"], size: m["size"] || 0, modified: m["modified_at"]}
          end)

        {:ok, parsed}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def chat(messages, opts \\ []) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, default_model())

    body =
      %{
        model: model,
        messages: format_messages(messages),
        stream: false,
        keep_alive: "30m",
        options: %{temperature: Keyword.get(opts, :temperature, 0.7)}
      }
      |> maybe_add_tools(model, opts)

    try do
      case Req.post("#{url}/api/chat", json: body, receive_timeout: 120_000) do
        {:ok, %{status: 200, body: %{"message" => %{"content" => content} = msg}}} ->
          tool_calls = parse_tool_calls(msg)
          {:ok, %{content: Text.strip_thinking_tokens(content || ""), tool_calls: tool_calls}}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("Ollama returned #{status}: #{inspect(resp_body)}")
          {:error, "Ollama returned #{status}: #{inspect(resp_body)}"}

        {:error, reason} ->
          Logger.error("Ollama connection failed: #{inspect(reason)}")
          {:error, "Ollama connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Logger.error("Ollama unexpected error: #{Exception.message(e)}")
        {:error, "Ollama unexpected error: #{Exception.message(e)}"}
    end
  end

  # --- Private ---

  defp pick_best_model(models) do
    # Filter to tool-capable models (by prefix + size), sort by size descending
    tool_capable =
      models
      |> Enum.filter(fn m ->
        name = String.downcase(m.name)

        m.size >= @tool_min_size and
          Enum.any?(@tool_capable_prefixes, &String.starts_with?(name, &1))
      end)
      |> Enum.sort_by(& &1.size, :desc)

    case tool_capable do
      [best | _] ->
        best

      [] ->
        # Fallback: just pick the largest model ≥ 4GB
        models
        |> Enum.filter(fn m -> m.size >= 4_000_000_000 end)
        |> Enum.sort_by(& &1.size, :desc)
        |> List.first()
    end
  end

  @doc """
  Check if a model name matches known tool-capable prefixes.
  Returns true for models that can handle function/tool calling reliably.
  """
  @spec model_supports_tools?(String.t()) :: boolean()
  def model_supports_tools?(model_name) do
    name = String.downcase(model_name)

    Enum.any?(@tool_capable_prefixes, &String.starts_with?(name, &1)) and
      not String.contains?(name, ":1.") and
      not String.contains?(name, ":3b")
  end

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

  defp maybe_add_tools(body, model, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      [] ->
        body

      tools ->
        if model_supports_tools?(model) do
          Map.put(body, :tools, format_tools(tools))
        else
          Logger.debug("[Ollama] Skipping tools for #{model} (too small / not tool-capable)")
          body
        end
    end
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
      }
    end)
  end

  defp parse_tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        id: call["id"] || generate_id(),
        name: call["function"]["name"],
        arguments: call["function"]["arguments"] || %{}
      }
    end)
  end

  defp parse_tool_calls(_), do: []

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()
end
