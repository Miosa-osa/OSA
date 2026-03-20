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

  alias OptimalSystemAgent.Providers.ToolCallParsers
  alias OptimalSystemAgent.Utils.Text

  # Models known to handle tool calling well (name prefix → min size in GB)
  # Include both hyphenated and non-hyphenated variants (glm-4 AND glm4)
  @tool_capable_prefixes ~w(qwen3 qwen2.5 qwen2 qwen llama3.3 llama3.2 llama3.1 llama3 llama2 llama gemma3 gemma2 gemma glm-5 glm5 glm-4 glm4 glm4.7 mistral mixtral deepseek command-r kimi kimi-k2 minimax nemotron phi3 phi2 phi hermes nous openchat vicuna falcon orca solar yi internlm codellama starcoder wizardcoder dolphin)

  # Minimum model size (in bytes) to enable tool calling — ~14B params ≈ 8GB on disk
  @tool_min_size 7_000_000_000

  @impl true
  def name, do: :ollama

  @impl true
  def default_model do
    # Return whatever auto-detect found, not a hardcoded small model
    Application.get_env(:optimal_system_agent, :ollama_model, "llama3.2:latest")
  end

  @impl true
  def available_models do
    case list_models() do
      {:ok, models} -> Enum.map(models, & &1.name)
      {:error, _} -> [default_model()]
    end
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

  @doc """
  Returns true when the Ollama server is reachable at the configured URL.

  Uses a 2-second HTTP probe to /api/tags. Called by the shim
  `OptimalSystemAgent.Providers.Ollama.reachable?/0` and by `Onboarding` boot checks.
  """
  @spec reachable?() :: boolean()
  def reachable? do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case Req.get("#{url}/api/tags", [{:receive_timeout, 2_000}, {:retry, false}] ++ auth_headers()) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "List models available on the Ollama server."
  @spec list_models(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_models(url \\ nil) do
    url = url || Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    case Req.get("#{url}/api/tags", [{:receive_timeout, 5_000}, {:retry, false}] ++ auth_headers()) do
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
      |> maybe_add_think(model, opts)

    # 600 s — thinking models (kimi-k2.5) need up to ~300 s before producing
    # any output; 120 s was too short and caused Cortex synthesis timeouts.
    req_opts = [
      json: body,
      receive_timeout: 600_000,
      pool_timeout: 60_000,
      retry: false
    ] ++ auth_headers()

    try do
      req = Req.new(req_opts) |> Req.merge(url: "#{url}/api/chat")
      case Req.post(req) do
        {:ok, %{status: 200, body: %{"message" => %{"content" => content} = msg}}} ->
          tool_calls = parse_tool_calls(msg, model)
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

  @impl true
  def chat_stream(messages, callback, opts \\ []) do
    url = Application.get_env(:optimal_system_agent, :ollama_url, "http://localhost:11434")

    # Ollama Cloud (HTTPS) — streaming via Erlang port + curl --no-buffer.
    # Req/Finch pool gets stuck after boot failures with HTTPS endpoints,
    # so we use curl as a subprocess with an Erlang port for line-by-line
    # NDJSON streaming. Each JSON line contains a token delta.
    if String.starts_with?(url, "https://") do
      Logger.info("[Ollama] Cloud URL detected — streaming via curl port")
      model = Keyword.get(opts, :model) || Application.get_env(:optimal_system_agent, :ollama_model, default_model())
      tools = Keyword.get(opts, :tools, [])

      body_map = %{
        model: model,
        messages: format_messages(messages),
        stream: true,
        options: %{temperature: Keyword.get(opts, :temperature, 0.7)}
      }

      body_map = if tools != [] and model_supports_tools?(model) do
        Map.put(body_map, :tools, format_tools(tools))
      else
        body_map
      end

      body = Jason.encode!(body_map)
      api_key = Application.get_env(:optimal_system_agent, :ollama_api_key, "")

      tool_count = length(Map.get(body_map, :tools, []))
      Logger.info("[Ollama] Cloud request: model=#{model}, tools=#{tool_count}, body_size=#{byte_size(body)}")

      # Write body to a temp file to avoid shell quoting issues with large JSON
      body_file = Path.join(System.tmp_dir!(), "osa_ollama_body_#{:erlang.unique_integer([:positive])}.json")
      File.write!(body_file, body)

      # Use spawn_executable with explicit args to avoid shell quoting issues
      curl_exe = System.find_executable("curl") || "curl"
      curl_args = [
        "-sN", "--max-time", "300",
        "-H", "Content-Type: application/json",
        "-H", "Authorization: Bearer #{api_key}",
        "-d", "@#{body_file}",
        "#{url}/api/chat"
      ]
      port = Port.open({:spawn_executable, curl_exe}, [:binary, :exit_status, {:line, 1_048_576}, {:args, curl_args}])

      result = cloud_stream_loop(port, callback, %{content: "", tool_calls: [], usage: %{}})
      File.rm(body_file)
      result
    else
      chat_stream_impl(messages, callback, opts, url)
    end
  end

  # Read streaming NDJSON from curl port line by line.
  # Each line is a JSON object with {"message": {"content": "token"}, "done": false}.
  # Final line has "done": true with usage stats.
  defp cloud_stream_loop(port, callback, acc) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"done" => true} = resp} ->
            # Final chunk — extract usage stats. Tool calls may have arrived in
            # earlier chunks (streaming mode sends them before done:true).
            raw_tool_calls = get_in(resp, ["message", "tool_calls"]) || []
            model = get_in(resp, ["model"]) || ""
            final_tool_calls = parse_tool_calls(%{"tool_calls" => raw_tool_calls}, model)
            # Merge: tool calls from mid-stream chunks + any in the final chunk
            tool_calls = acc.tool_calls ++ final_tool_calls

            usage = %{
              input_tokens: resp["prompt_eval_count"] || 0,
              output_tokens: resp["eval_count"] || 0,
              total_tokens: (resp["prompt_eval_count"] || 0) + (resp["eval_count"] || 0)
            }

            # Some models (e.g. nemotron cloud) send all content in the done:true chunk
            # rather than via intermediate streaming chunks. Fall back to that if needed.
            final_content_from_chunk = get_in(resp, ["message", "content"]) || ""
            accumulated = if acc.content == "" and final_content_from_chunk != "",
              do: final_content_from_chunk,
              else: acc.content
            content = Text.strip_thinking_tokens(accumulated)
            Logger.info("[Ollama] Cloud stream done: #{byte_size(content)} bytes, #{length(tool_calls)} tool calls, #{usage.total_tokens} tokens")
            callback.({:done, %{content: content, tool_calls: tool_calls, usage: usage}})
            # Wait for port exit
            receive do
              {^port, {:exit_status, _}} -> :ok
            after
              5_000 -> Port.close(port)
            end
            :ok

          {:ok, %{"message" => %{"tool_calls" => tool_calls_raw}} = resp} when is_list(tool_calls_raw) and tool_calls_raw != [] ->
            # Tool call chunk (comes BEFORE done:true in streaming mode)
            model = get_in(resp, ["model"]) || ""
            tool_calls = parse_tool_calls(%{"tool_calls" => tool_calls_raw}, model)
            Logger.info("[Ollama] Cloud stream: got #{length(tool_calls)} tool calls mid-stream")
            cloud_stream_loop(port, callback, %{acc | tool_calls: acc.tool_calls ++ tool_calls})

          {:ok, %{"message" => %{"content" => token}}} when token != "" ->
            # Streaming token — emit delta
            callback.({:text_delta, token})
            cloud_stream_loop(port, callback, %{acc | content: acc.content <> token})

          {:ok, %{"error" => error}} ->
            # API returned an error — fail fast instead of looping forever
            Port.close(port)
            Logger.error("[Ollama] Cloud API error: #{error}")
            callback.({:error, "Ollama Cloud: #{error}"})
            {:error, "Ollama Cloud: #{error}"}

          {:ok, _} ->
            # Empty token or other chunk, continue
            cloud_stream_loop(port, callback, acc)

          {:error, _} ->
            # Non-JSON line (curl progress etc), skip
            cloud_stream_loop(port, callback, acc)
        end

      {^port, {:data, {:noeol, _partial}}} ->
        # Partial line, wait for more
        cloud_stream_loop(port, callback, acc)

      {^port, {:exit_status, 0}} ->
        # curl exited cleanly but we didn't get a done:true — finalize.
        # Always call done callback even when content is empty (tool-call-only
        # responses have no text but do have tool_calls; skipping would block
        # the caller indefinitely on its receive loop).
        content = Text.strip_thinking_tokens(acc.content)
        callback.({:done, %{content: content, tool_calls: acc.tool_calls, usage: acc.usage}})
        :ok

      {^port, {:exit_status, code}} ->
        Logger.error("[Ollama] Cloud curl exited with code #{code}")
        {:error, "Ollama Cloud curl failed (exit #{code})"}

    after
      300_000 ->
        Port.close(port)
        {:error, "Ollama Cloud timeout after 300s"}
    end
  end

  defp chat_stream_impl(messages, callback, opts, url) do

    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, default_model())

    body =
      %{
        model: model,
        messages: format_messages(messages),
        stream: true,
        options: %{temperature: Keyword.get(opts, :temperature, 0.7)}
      }
      |> maybe_add_tools(model, opts)
      |> maybe_add_think(model, opts)

    # Use into: fn (synchronous callback) instead of into: :self.
    # With plain HTTP (Ollama localhost), Req/Finch delivers chunks as
    # {{Finch.HTTP1.Pool, pid}, {:data, binary}} — a format that doesn't match
    # the {ref, {:data, binary}} patterns used by the mailbox-based receive loop.
    # The callback approach runs directly in the calling process, bypassing all
    # mailbox message format differences between HTTP and HTTPS connections.
    stream_key = {__MODULE__, :stream, make_ref()}
    Process.put(stream_key, %{buffer: "", content: "", tool_calls: [], usage: %{}})

    req_opts =
      [
        json: body,
        receive_timeout: 600_000,
        into: fn {:data, data}, {req, resp} ->
          acc = Process.get(stream_key)
          acc = handle_stream_chunk(data, callback, acc)
          Process.put(stream_key, acc)
          {:cont, {req, resp}}
        end
      ] ++ auth_headers()

    Logger.debug("[Ollama] Starting chat_stream to #{url}/api/chat model=#{model}")
    try do
      case Req.post("#{url}/api/chat", req_opts) do
        {:ok, _resp} ->
          Logger.debug("[Ollama] chat_stream completed successfully")
          acc = Process.get(stream_key)
          Process.delete(stream_key)
          finalize_stream(acc, callback)

        {:error, reason} ->
          Process.delete(stream_key)
          Logger.error("Ollama stream connection failed: #{inspect(reason)}")
          {:error, "Ollama stream connection failed: #{inspect(reason)}"}
      end
    rescue
      e ->
        Process.delete(stream_key)
        Logger.error("Ollama stream unexpected error: #{Exception.message(e)}")
        {:error, "Ollama stream unexpected error: #{Exception.message(e)}"}
    end
  end

  # --- Private (exposed @doc false for unit testing) ---

  @doc false
  def pick_best_model(models) do
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
      # Assistant messages that carry tool_calls must preserve them so that
      # the 2nd+ iteration has accurate conversation history.
      %{role: "assistant", tool_calls: tool_calls} = msg when is_list(tool_calls) and tool_calls != [] ->
        formatted_calls =
          Enum.map(tool_calls, fn tc ->
            %{
              "id" => tc.id,
              "type" => "function",
              "function" => %{"name" => normalize_tool_name(tc.name), "arguments" => tc.arguments}
            }
          end)

        content = Map.get(msg, :content, "") || ""
        %{"role" => "assistant", "content" => to_string(content), "tool_calls" => formatted_calls}

      # Tool result messages — must carry tool_call_id and name so the model
      # can attribute the result to the correct call on iteration 2+.
      # This clause must come before the generic %{role, content} catch-all
      # because that clause would silently drop tool_call_id and name.
      %{role: "tool", content: content, tool_call_id: id} = msg ->
        name = Map.get(msg, :name, "")
        %{
          "role" => "tool",
          "content" => to_string(content),
          "tool_call_id" => to_string(id),
          "name" => to_string(name)
        }

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

  # Controls the `think` field for Ollama reasoning models (kimi, qwen3 thinking, etc.)
  # Default: disabled for known thinking models to prevent unbounded timeouts.
  # Override per-call: opts[:think] = true/false
  # Override globally: OLLAMA_THINK=true in .env (sets :ollama_think in app env)
  defp maybe_add_think(body, model, opts) do
    case Keyword.get(opts, :think) do
      nil ->
        think_cfg = Application.get_env(:optimal_system_agent, :ollama_think)

        cond do
          think_cfg != nil ->
            Map.put(body, "think", think_cfg)

          thinking_model?(model) ->
            # Disable extended reasoning by default — prevents 10+ minute stalls
            Map.put(body, "think", false)

          true ->
            body
        end

      val ->
        Map.put(body, "think", val)
    end
  end

  # Returns true for models known to enter unbounded thinking phases by default.
  @doc false
  def thinking_model?(model_name) do
    name = String.downcase(model_name)
    String.contains?(name, "thinking") or String.starts_with?(name, "kimi")
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

  defp parse_tool_calls(%{"tool_calls" => calls}, _model) when is_list(calls) do
    Enum.flat_map(calls, fn call ->
      case call do
        %{"function" => %{"name" => name} = func} ->
          [%{
            id: call["id"] || generate_id(),
            name: normalize_tool_name(name),
            arguments: Map.get(func, "arguments", %{})
          }]

        %{"name" => name} ->
          [%{
            id: call["id"] || generate_id(),
            name: normalize_tool_name(name),
            arguments: call["arguments"] || %{}
          }]

        _ ->
          Logger.warning("[Ollama] Skipping malformed tool_call: #{inspect(call)}")
          []
      end
    end)
  end

  defp parse_tool_calls(%{"content" => content}, model) when is_binary(content) do
    ToolCallParsers.parse(content, model)
  end

  defp parse_tool_calls(_, _model), do: []

  defp generate_id,
    do: OptimalSystemAgent.Utils.ID.generate()

  defp handle_stream_chunk(data, callback, acc) do
    {lines, new_buffer} = split_ndjson(acc.buffer <> data)
    acc = %{acc | buffer: new_buffer}
    Enum.reduce(lines, acc, &process_ndjson_line(&1, callback, &2))
  end

  defp finalize_stream(acc, callback) do
    content = Text.strip_thinking_tokens(acc.content)

    tool_calls =
      if acc.tool_calls != [],
        do: acc.tool_calls,
        else: ToolCallParsers.parse(acc.content, "ollama")

    # Pass through usage captured from the done:true chunk (prompt_eval_count/eval_count).
    # Keys already normalised to :input_tokens/:output_tokens by process_ndjson_line.
    callback.({:done, %{content: content, tool_calls: tool_calls, usage: acc.usage}})
    :ok
  end

  # Split buffered data into complete NDJSON lines + partial remainder
  @doc false
  def split_ndjson(data) do
    lines = String.split(data, "\n")
    {complete, [remainder]} = Enum.split(lines, -1)
    {Enum.reject(complete, &(&1 == "")), remainder}
  end

  @doc false
  def process_ndjson_line(line, callback, acc) do
    case Jason.decode(line) do
      {:ok, %{"message" => %{"content" => text}}} when is_binary(text) and text != "" ->
        callback.({:text_delta, text})
        %{acc | content: acc.content <> text}

      # kimi-k2.5 and other thinking models send a "thinking" field during
      # extended reasoning before producing content or tool calls.
      {:ok, %{"message" => %{"thinking" => text}}} when is_binary(text) and text != "" ->
        callback.({:thinking_delta, text})
        acc

      {:ok, %{"message" => %{"tool_calls" => calls}}} when is_list(calls) ->
        tool_calls =
          Enum.flat_map(calls, fn call ->
            case call do
              %{"function" => %{"name" => name} = func} ->
                [%{
                  id: call["id"] || generate_id(),
                  name: normalize_tool_name(name),
                  arguments: Map.get(func, "arguments", %{})
                }]

              %{"name" => name} ->
                [%{
                  id: call["id"] || generate_id(),
                  name: normalize_tool_name(name),
                  arguments: call["arguments"] || %{}
                }]

              _ ->
                Logger.warning("[Ollama] Skipping malformed streaming tool_call: #{inspect(call)}")
                []
            end
          end)

        %{acc | tool_calls: acc.tool_calls ++ tool_calls}

      # Final chunk — capture usage stats so context pressure reports correctly.
      # Keys normalised to :input_tokens/:output_tokens to match what loop.ex reads.
      {:ok, %{"done" => true} = resp} ->
        usage = %{
          input_tokens: resp["prompt_eval_count"] || 0,
          output_tokens: resp["eval_count"] || 0,
          total_tokens: (resp["prompt_eval_count"] || 0) + (resp["eval_count"] || 0)
        }
        %{acc | usage: usage}

      _ ->
        acc
    end
  end

  # Strip any arguments that some models concatenate to the tool name.
  # e.g. "dir_list {\"path\": \".\"}" → "dir_list"
  defp normalize_tool_name(name) when is_binary(name) do
    name |> String.split(~r/[\s({]/) |> List.first() |> String.trim()
  end

  defp normalize_tool_name(name), do: name

  # Returns `[headers: [{"authorization", "Bearer <key>"}]]` when
  # OLLAMA_API_KEY is set (Ollama Cloud), empty list otherwise.
  defp auth_headers do
    case Application.get_env(:optimal_system_agent, :ollama_api_key) do
      key when is_binary(key) and key != "" ->
        [headers: [{"authorization", "Bearer #{key}"}]]

      _ ->
        []
    end
  end
end
