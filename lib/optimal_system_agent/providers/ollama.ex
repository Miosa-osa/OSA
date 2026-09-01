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

  alias OptimalSystemAgent.Providers.ThinkStreamParser
  alias OptimalSystemAgent.Providers.ToolCallParsers
  alias OptimalSystemAgent.Utils.Mojibake
  alias OptimalSystemAgent.Utils.Text

  # Models known to handle tool calling well (name prefix → min size in GB)
  # Include both hyphenated and non-hyphenated variants (glm-4 AND glm4)
  @tool_capable_prefixes ~w(qwen3 qwen2.5 qwen2 qwen llama3.3 llama3.2 llama3.1 llama3 llama2 llama gemma3 gemma2 gemma glm-5 glm5 glm-4 glm4 glm4.7 mistral mixtral deepseek command-r kimi kimi-k2 minimax nemotron phi3 phi2 phi hermes nous openchat vicuna falcon orca solar yi internlm codellama starcoder wizardcoder dolphin)

  # Minimum model size (in bytes) to enable tool calling — ~14B params ≈ 8GB on disk
  @tool_min_size 7_000_000_000

  @local_url "http://localhost:11434"

  @impl true
  def name, do: :ollama

  # Tool schemas ride in a dedicated field of the request body, not in the
  # system-prompt text. See Providers.Behaviour.native_tool_schemas?/0.
  @impl true
  def native_tool_schemas?, do: true

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
    # Consider BOTH keys: a configured model may live on :default_model (reconciled
    # at boot) or :ollama_model (from OLLAMA_MODEL). Probing/clobbering must only
    # happen when NO model was configured from any source. Accepts :cloud models.
    explicit =
      Application.get_env(:optimal_system_agent, :default_model) ||
        Application.get_env(:optimal_system_agent, :ollama_model)

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

    case Req.get(
           "#{url}/api/tags",
           [{:receive_timeout, 2_000}, {:retry, false}] ++ auth_headers()
         ) do
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

    case Req.get(
           "#{url}/api/tags",
           [{:receive_timeout, 5_000}, {:retry, false}] ++ auth_headers()
         ) do
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

  @doc """
  The URL of the daemon on THIS machine.

  `:ollama_url` is whatever onboarding last wrote — picking a cloud model
  leaves it at `https://ollama.com`. That is a hosted endpoint, not a local
  daemon; anything that means "the local daemon" (the picker's reachability
  probe, `/model list`, routing local weights) must not read it as one.
  """
  @spec local_daemon_url() :: String.t()
  def local_daemon_url do
    configured = Application.get_env(:optimal_system_agent, :ollama_url, @local_url)

    if is_binary(configured) and String.starts_with?(configured, "https://"),
      do: Application.get_env(:optimal_system_agent, :ollama_local_url, @local_url),
      else: configured
  end

  @doc false
  # A hosted URL (`https://ollama.com`) cannot serve local weights at all, and
  # it only serves a `:cloud` tag the account is entitled to. So whenever the
  # local daemon has the model, the local daemon is the right route — the
  # signed daemon proxies cloud tags key-free, and it is the ONLY thing that
  # can run a GGUF pulled with `ollama pull hf.co/…`. Before, this only
  # rerouted cloud tags: a local model selected while `OLLAMA_URL=https://ollama.com`
  # was sent to ollama.com and failed.
  @spec resolve_request_url(String.t(), String.t() | nil, [String.t()]) :: String.t()
  def resolve_request_url(configured_url, model, local_model_names) do
    if String.starts_with?(configured_url, "https://") and model in local_model_names do
      @local_url
    else
      configured_url
    end
  end

  defp request_url(configured_url, model) do
    if String.starts_with?(configured_url, "https://") and is_binary(model) do
      local_url = Application.get_env(:optimal_system_agent, :ollama_local_url, @local_url)

      # Hosted tags are not guaranteed to appear in /api/tags even when the
      # signed daemon can serve them. /api/show is Ollama's authoritative
      # per-model capability check and does not start a generation.
      local_model_names =
        case Req.post("#{local_url}/api/show",
               json: %{model: model},
               receive_timeout: 750,
               retry: false
             ) do
          {:ok, %{status: 200}} -> [model]
          _ -> []
        end

      case resolve_request_url(configured_url, model, local_model_names) do
        @local_url ->
          Logger.info("[Ollama] Routing #{model} through the local daemon (it serves it)")

          local_url

        url ->
          url
      end
    else
      configured_url
    end
  rescue
    _ -> configured_url
  end

  @impl true
  def chat(messages, opts \\ []) do
    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, default_model())

    configured_url = Application.get_env(:optimal_system_agent, :ollama_url, @local_url)
    url = request_url(configured_url, model)

    with :ok <- context_floor_error(model, opts) do
      do_chat(url, model, messages, opts)
    end
  end

  defp do_chat(url, model, messages, opts) do
    body =
      %{
        model: model,
        messages: format_messages(messages),
        stream: false,
        keep_alive: keep_alive(),
        options: build_options(opts, messages, model)
      }
      |> maybe_add_tools(model, opts)
      |> maybe_add_think(model, opts)

    req_opts =
      [
        json: body,
        receive_timeout: receive_timeout_ms(),
        pool_timeout: 60_000,
        retry: false
      ] ++ auth_headers()

    try do
      req = Req.new(req_opts) |> Req.merge(url: "#{url}/api/chat")

      case Req.post(req) do
        {:ok, %{status: 200, body: %{"message" => %{"content" => content} = msg} = resp}} ->
          tool_calls = parse_tool_calls(msg, model)

          {:ok,
           %{
             content: Text.strip_thinking_tokens(content || ""),
             tool_calls: tool_calls,
             # `done_reason` is Ollama's terminal stop reason ("stop" | "length"
             # | "load" | "unload"). It was never read: a generation that ran out
             # of `num_predict` came back indistinguishable from one the model
             # ended itself, so `ReactLoop`'s truncation recovery could not fire
             # on OSA's DEFAULT provider. See `Providers.StopReason`.
             stop_reason: resp["done_reason"]
           }}

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
    model =
      Keyword.get(opts, :model) ||
        Application.get_env(:optimal_system_agent, :ollama_model, default_model())

    # Fail fast BEFORE any bytes go out. `effective_context_window/2` applies
    # the local ceiling only to non-cloud tags, so an Ollama Cloud model passes
    # this untouched.
    with :ok <- context_floor_error(model, opts) do
      do_chat_stream(messages, callback, opts, model)
    end
  end

  defp do_chat_stream(messages, callback, opts, model) do
    configured_url = Application.get_env(:optimal_system_agent, :ollama_url, @local_url)
    url = request_url(configured_url, model)

    # Ollama Cloud (HTTPS) — streaming via Erlang port + curl --no-buffer.
    # Req/Finch pool gets stuck after boot failures with HTTPS endpoints,
    # so we use curl as a subprocess with an Erlang port for line-by-line
    # NDJSON streaming. Each JSON line contains a token delta.
    if String.starts_with?(url, "https://") do
      Logger.info("[Ollama] Cloud URL detected — streaming via curl port")

      tools = Keyword.get(opts, :tools, [])
      body_map = build_cloud_body(model, messages, opts, tools)
      body = Jason.encode!(body_map)
      api_key = Application.get_env(:optimal_system_agent, :ollama_api_key, "")

      tool_count = length(Map.get(body_map, :tools, []))

      Logger.info(
        "[Ollama] Cloud request: model=#{model}, tools=#{tool_count}, body_size=#{byte_size(body)}"
      )

      # Write body to a 0600 temp file to avoid shell quoting issues with large
      # JSON, and the auth header to a 0600 curl config file — NEVER to argv.
      body_file = write_private_temp!("osa_ollama_body", ".json", body)
      config_file = write_private_temp!("osa_ollama_curl", ".conf", curl_config(api_key))

      # Use spawn_executable with explicit args to avoid shell quoting issues
      curl_exe = System.find_executable("curl") || "curl"

      port =
        Port.open({:spawn_executable, curl_exe}, [
          :binary,
          :exit_status,
          {:line, 1_048_576},
          {:args, curl_args(config_file, body_file, url)},
          # curl gets its credential from the 0600 config file, never from the
          # environment, so there is nothing here it needs and everything to
          # lose: a redirected/hostile URL should not be able to reach a
          # provider key through a `-w`/config trick.
          {:env, OptimalSystemAgent.OS.Env.port_env()}
        ])

      result =
        cloud_stream_loop(port, callback, %{
          content: "",
          tool_calls: [],
          usage: %{},
          # Reassembly buffer for NDJSON lines longer than the port's `{:line,
          # 1_048_576}` limit. The port delivers such a line as one or more
          # `{:noeol, chunk}` fragments followed by a final `{:eol, tail}`;
          # holding the fragments here and prepending them to the tail before
          # `Jason.decode` is what stops a >1 MB line (a big tool-call's
          # arguments, or a model that returns the whole answer in the done chunk)
          # from being silently truncated and dropped.
          partial: "",
          # Terminal `done_reason` from the final NDJSON chunk, when one arrives.
          stop_reason: nil,
          # Split inline <think>…</think> reasoning out of the live stream so
          # the tags + reasoning never leak into the visible answer (GLM cloud
          # models such as glm-5.2:cloud inline reasoning in the content field).
          think: ThinkStreamParser.new(),
          # WS1 (Grok dual idle-timeout): the llm_client idle-watchdog atomic.
          # Bumped on EVERY raw chunk received from the curl port below — before
          # parsing, even for keepalive/blank/non-JSON bytes — so the idle timer
          # measures TRUE silence on the pipe, not just gaps between parsed
          # events. `nil` when called outside the agent loop (direct provider
          # test), which `bump_heartbeat/1` treats as a no-op.
          heartbeat: Keyword.get(opts, :heartbeat)
        })

      File.rm(body_file)
      File.rm(config_file)
      result
    else
      chat_stream_impl(messages, callback, opts, url)
    end
  end

  # ── curl invocation (secret never reaches argv) ──────────────────────
  #
  # `/proc/<pid>/cmdline` is world-readable on Linux, and `ps` shows the full
  # argv to every local user. The Ollama Cloud bearer token used to be an argv
  # element (`-H "Authorization: Bearer <token>"`), so every local user could
  # read it on every single request. The token now goes into a 0600 curl config
  # file passed by path; argv carries nothing sensitive.

  @doc false
  @spec curl_args(String.t(), String.t(), String.t()) :: [String.t()]
  def curl_args(config_file, body_file, url) do
    [
      "-sN",
      "--max-time",
      "300",
      "-H",
      "Content-Type: application/json",
      # Authorization header lives here, not in argv.
      "--config",
      config_file,
      "-d",
      "@#{body_file}",
      "#{url}/api/chat"
    ]
  end

  @doc false
  @spec curl_config(String.t() | nil) :: String.t()
  def curl_config(api_key) when is_binary(api_key) and api_key != "" do
    ~s(header = "Authorization: Bearer #{escape_curl_config_value(api_key)}"\n)
  end

  def curl_config(_api_key), do: ""

  # curl config files use backslash escapes inside double-quoted values.
  defp escape_curl_config_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  # Create at 0600 BEFORE writing anything. `File.write!` followed by
  # `File.chmod!` leaves a TOCTOU window in which the default umask (commonly
  # 0644) exposes the contents to every local user.
  defp write_private_temp!(prefix, ext, content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{:erlang.unique_integer([:positive])}#{ext}"
      )

    {:ok, io} = File.open(path, [:write, :binary, :exclusive])
    :ok = File.chmod(path, 0o600)

    try do
      IO.binwrite(io, content)
    after
      File.close(io)
    end

    path
  end

  # Read streaming NDJSON from curl port line by line.
  # Each line is a JSON object with {"message": {"content": "token"}, "done": false}.
  # Final line has "done": true with usage stats.
  defp cloud_stream_loop(port, callback, acc) do
    receive do
      {^port, {:data, {:eol, tail}}} ->
        # Raw bytes arrived → reset the idle watchdog BEFORE parsing, so even a
        # keepalive or non-JSON line counts as the pipe being alive (WS1).
        bump_heartbeat(Map.get(acc, :heartbeat))

        # Prepend any held `:noeol` fragments of an oversized line, then clear the
        # buffer so the next line starts fresh. `acc.partial` is "" for the common
        # (sub-1-MB) line, so this is a no-op there.
        line = Map.get(acc, :partial, "") <> tail
        acc = %{acc | partial: ""}

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

            accumulated =
              if acc.content == "" and final_content_from_chunk != "",
                do: final_content_from_chunk,
                else: acc.content

            # Drain any tag tail the splitter was holding so trailing characters
            # are never lost from the live display at end-of-stream.
            flush_think(acc, callback)

            content = Text.strip_thinking_tokens(accumulated)

            Logger.info(
              "[Ollama] Cloud stream done: #{byte_size(content)} bytes, #{length(tool_calls)} tool calls, #{usage.total_tokens} tokens"
            )

            # `done_reason` — Ollama's terminal stop reason. "length" means the
            # generation was cut off at `num_predict` and is NOT an answer.
            callback.(
              {:done,
               %{
                 content: content,
                 tool_calls: tool_calls,
                 usage: usage,
                 stop_reason: resp["done_reason"]
               }}
            )

            # Wait for port exit
            receive do
              {^port, {:exit_status, _}} -> :ok
            after
              5_000 -> Port.close(port)
            end

            :ok

          {:ok, %{"message" => %{"tool_calls" => tool_calls_raw}} = resp}
          when is_list(tool_calls_raw) and tool_calls_raw != [] ->
            # Tool call chunk (comes BEFORE done:true in streaming mode)
            model = get_in(resp, ["model"]) || ""
            tool_calls = parse_tool_calls(%{"tool_calls" => tool_calls_raw}, model)
            Logger.info("[Ollama] Cloud stream: got #{length(tool_calls)} tool calls mid-stream")
            cloud_stream_loop(port, callback, %{acc | tool_calls: acc.tool_calls ++ tool_calls})

          {:ok, %{"message" => %{"thinking" => think_token, "content" => token}}}
          when is_binary(think_token) and think_token != "" and
                 is_binary(token) and token != "" ->
            # A SINGLE chunk carrying BOTH native reasoning AND visible content.
            # The thinking-only arm below matches any chunk with a non-empty
            # `thinking` key, so without this arm a both-present chunk routed the
            # reasoning and silently DROPPED the content. Emit the reasoning to
            # the thinking box, then run the content through the SAME
            # ThinkStreamParser the content-only arm uses (state threaded), so
            # the visible answer is never lost.
            callback.({:thinking_delta, think_token})

            {visible, thinking, think_state} =
              ThinkStreamParser.feed(acc.think, token)

            if thinking != "", do: callback.({:thinking_delta, thinking})
            if visible != "", do: callback.({:text_delta, visible})

            cloud_stream_loop(port, callback, %{
              acc
              | content: acc.content <> token,
                think: think_state
            })

          {:ok, %{"message" => %{"thinking" => think_token}}}
          when is_binary(think_token) and think_token != "" ->
            # Native reasoning channel (`think: true`). Reasoning arrives on its
            # OWN `thinking` field, separate from `content`, so route it straight
            # to the thinking box and leave the visible answer untouched. Without
            # this arm the chunk fell to the catch-all and the reasoning was
            # dropped; the arm exists so a reasoning model shows its reasoning
            # like the `ollama` CLI does.
            callback.({:thinking_delta, think_token})
            cloud_stream_loop(port, callback, acc)

          {:ok, %{"message" => %{"content" => token}}} when token != "" ->
            # Streaming token — split inline reasoning tags out before emitting.
            # (Belt-and-suspenders: with `think: true` reasoning comes on the
            # `thinking` field above, but a model that still inlines `<think>`
            # tags is handled here too.)
            {visible, thinking, think_state} =
              ThinkStreamParser.feed(acc.think, token)

            if thinking != "", do: callback.({:thinking_delta, thinking})
            if visible != "", do: callback.({:text_delta, visible})

            cloud_stream_loop(port, callback, %{
              acc
              | content: acc.content <> token,
                think: think_state
            })

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

      {^port, {:data, {:noeol, fragment}}} ->
        # A line longer than the port's `{:line, N}` limit arrives as `:noeol`
        # fragments before its `:eol` tail. Accumulate them (was previously
        # DISCARDED, truncating the line) and reset the idle watchdog (WS1).
        bump_heartbeat(Map.get(acc, :heartbeat))
        cloud_stream_loop(port, callback, %{acc | partial: Map.get(acc, :partial, "") <> fragment})

      {^port, {:exit_status, 0}} ->
        # curl exited cleanly but we didn't get a done:true — finalize.
        # Always call done callback even when content is empty (tool-call-only
        # responses have no text but do have tool_calls; skipping would block
        # the caller indefinitely on its receive loop).
        flush_think(acc, callback)
        content = Text.strip_thinking_tokens(acc.content)

        callback.(
          {:done,
           %{
             content: content,
             tool_calls: acc.tool_calls,
             usage: acc.usage,
             stop_reason: Map.get(acc, :stop_reason)
           }}
        )

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
        keep_alive: keep_alive(),
        options: build_options(opts, messages, model)
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

    Process.put(stream_key, %{
      buffer: "",
      content: "",
      tool_calls: [],
      usage: %{},
      # Terminal `done_reason` from the final NDJSON chunk ("stop" | "length").
      stop_reason: nil,
      think: ThinkStreamParser.new()
    })

    # WS1 (Grok dual idle-timeout): the llm_client idle-watchdog atomic. Reset on
    # EVERY raw chunk Finch delivers — before parsing — so a stream trickling
    # bytes never false-times-out; only a truly silent socket trips the idle
    # timer. `nil` outside the agent loop, which `bump_heartbeat/1` no-ops.
    heartbeat = Keyword.get(opts, :heartbeat)

    req_opts =
      [
        json: body,
        receive_timeout: receive_timeout_ms(),
        into: fn {:data, data}, {req, resp} ->
          bump_heartbeat(heartbeat)
          acc = Process.get(stream_key)
          acc = handle_stream_chunk(data, callback, acc)
          Process.put(stream_key, acc)
          {:cont, {req, resp}}
        end
      ] ++ auth_headers()

    Logger.debug("[Ollama] Starting chat_stream to #{url}/api/chat model=#{model}")

    try do
      case Req.post("#{url}/api/chat", req_opts) do
        {:ok, %{status: status}} when status != 200 ->
          # Non-200 (commonly 404 for a model that isn't pulled, or 500): the
          # error body isn't valid NDJSON so finalizing would report an empty
          # SUCCESS. Surface an error so the registry's fallback path engages.
          Process.delete(stream_key)
          Logger.warning("[Ollama] chat_stream HTTP #{status}")
          {:error, "Ollama stream HTTP #{status}"}

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
    {supported?, _source} = tools_decision(model_name, [])
    supported?
  end

  @doc """
  Whether to send tool schemas for `model`, and the rule that decided it.

  `{boolean, source}` where source is `:opt`, `:config`, `:cloud_capability`,
  `:catalog`, `:name_prefix`, `:tiny_model_guard` or `:unknown_model_default`.

  Same shape as `reasoning_decision/2`, and for the same reason. Stripping tools
  turns an agent into a chatbot — it cannot read a file, run a command, or
  finish a task — and this decision used to be made by a bare capability
  predicate with no override and a `Logger.debug`, so the most total capability
  loss in the provider was also its quietest.

  The change is confined to the UNKNOWN case. Authoritative answers are
  unchanged: `OllamaCloud.capability/2` reads the daemon's own `/api/show`
  `capabilities`, and `ModelLimits.tool_call/2` is the catalog; both are
  believed in either direction. The size guard is unchanged too — a 1B/3B model
  handed 23 tool schemas emits malformed calls rather than none, which is a real
  failure and a real guard.

  What flipped is a model whose NAME merely lacks a known prefix. That is not
  evidence of anything: `@tool_capable_prefixes` is a fixed list of families,
  and every model released after it was written fails it. Defaulting that to
  "no tools" meant an unrecognised name silently produced a crippled agent.
  It now defaults to sending them, so an actually tool-less model fails loudly
  at the provider — recoverable, visible, and correct far more often. Identical
  reasoning to `openai_compat.deepseek_endpoint?(nil) -> true`.

  `OLLAMA_TOOLS=false` / `opts[:tools_enabled]` override both directions.
  """
  @spec tools_decision(String.t() | nil, keyword()) :: {boolean(), atom()}
  def tools_decision(model_name, opts \\ []) do
    cond do
      is_boolean(val = Keyword.get(opts, :tools_enabled)) ->
        {val, :opt}

      is_boolean(cfg = Application.get_env(:optimal_system_agent, :ollama_tools)) ->
        {cfg, :config}

      true ->
        case OptimalSystemAgent.Providers.OllamaCloud.capability(model_name, :tools) do
          true ->
            {true, :cloud_capability}

          false ->
            {false, :cloud_capability}

          nil ->
            case OptimalSystemAgent.Providers.ModelLimits.tool_call(:ollama, model_name) do
              true -> {true, :catalog}
              false -> {false, :catalog}
              _ -> heuristic_tools_decision(model_name)
            end
        end
    end
  end

  # Name+size heuristic, used only when neither the daemon nor the catalog has
  # an authoritative answer.
  defp heuristic_tools_decision(model_name) do
    name = String.downcase(to_string(model_name))

    cond do
      # No model named. Not "unknown family" — no request at all.
      name == "" ->
        {false, :no_model}

      # An embedding model has no chat completion endpoint, let alone tool
      # calling. Unlike the prefix list this is a real capability fact and not a
      # guess about an unfamiliar name, so it stays a hard no.
      String.contains?(name, "embed") or String.contains?(name, "minilm") ->
        {false, :embedding_model}

      # A model this small cannot hold the schemas AND the task. Kept.
      String.contains?(name, ":1.") or String.contains?(name, ":3b") or
          String.contains?(name, ":1b") ->
        {false, :tiny_model_guard}

      Enum.any?(@tool_capable_prefixes, &String.starts_with?(name, &1)) ->
        {true, :name_prefix}

      # Unknown family. Not evidence of anything — send the tools.
      true ->
        {true, :unknown_model_default}
    end
  end

  # Build the Ollama `options` map with a right-sized context window.
  #
  # The bug this fixes: without an explicit num_ctx Ollama defaults it to 4096
  # (2048 on older builds) and silently LEFT-TRUNCATES any prompt larger than
  # that — discarding the system prompt and leaving the model an incoherent
  # tail, which is why local turns returned empty / "...".
  #
  # We size num_ctx to actually hold the prompt + the requested output, rounded
  # up to a sane bucket and capped at the window OSA is willing to allocate
  # (Registry.effective_context_window/2 — the SAME ceiling Agent.Context
  # budgets against, so budget and reality agree). `max_tokens` maps to Ollama's
  # `num_predict` (output cap); Ollama ignores `:max_tokens` entirely.
  defp build_options(opts, messages, model) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_ctx = OptimalSystemAgent.Providers.Registry.effective_context_window(model, :ollama)

    # Requested output cap (react_loop passes max_response_tokens, default 32768).
    # Floor at 256 so a bogus tiny/zero value can't starve generation.
    num_predict =
      opts
      |> Keyword.get(:max_tokens, 4096)
      |> max(256)
      |> cap_num_predict(model)

    prompt_tokens = OptimalSystemAgent.Agent.Context.estimate_tokens_messages(messages)

    # num_ctx must be >= prompt_tokens or Ollama truncates the prompt. Size it to
    # prompt + output + margin, bucket it, then cap at the real window. Because
    # Agent.Context already budgets the assembled prompt against this same
    # effective window, prompt_tokens stays under max_ctx and is never truncated;
    # any leftover room becomes generation headroom.
    # STABLE num_ctx: request the FULL effective window every turn, not a value
    # sized to the current prompt. The per-turn sizing grew num_ctx as the
    # conversation grew, and each bucket crossing forced Ollama to reload the
    # model — a 30s+ cold read on a 21 GB model — mid-session, and it thrashed
    # against any externally warmed instance. With a q4_0 KV cache a full-window
    # allocation is cheap (~700 MiB at 128k), so pin num_ctx to the window and
    # the model loads once and stays resident. Set :ollama_num_ctx_dynamic true
    # to restore the old prompt-sized behaviour.
    num_ctx =
      if Application.get_env(:optimal_system_agent, :ollama_num_ctx_dynamic, false) == true do
        (prompt_tokens + num_predict + 512)
        |> round_up_ctx()
        |> min(max_ctx)
      else
        max_ctx
      end

    # Never advertise a generation cap larger than the window itself.
    num_predict = min(num_predict, num_ctx)

    %{temperature: temperature, num_ctx: num_ctx, num_predict: num_predict}
  end

  # Cap num_predict (output tokens) at the model's real output ceiling when the
  # Catalog / static table knows it, so a large flat max_tokens (react_loop's
  # 32768 default) can't exceed a small-output model's limit and 400/truncate.
  defp cap_num_predict(n, model) do
    case OptimalSystemAgent.Providers.ModelLimits.max_output(model) do
      cap when is_integer(cap) and cap > 0 -> min(n, cap)
      _ -> n
    end
  end

  # Smallest window in which a tool-using turn is coherent. The tool schema
  # block alone runs to thousands of tokens before a single message is added,
  # so at 4096 the system prompt and the schemas cannot both fit — and Ollama
  # does not say so. It LEFT-TRUNCATES server-side, discarding the system
  # prompt and the earlier turns, and the model answers from an incoherent
  # tail. `round_up_ctx/1`'s 4096 floor and the `min(max_ctx)` cap between them
  # meant a too-small configured window was simply requested and honoured.
  @min_ctx_with_tools 8192

  @doc """
  `:ok`, or `{:error, message}` when this model's effective window is too small
  to run a tool-using turn.

  Fail fast and say which knob to turn. The alternative — the pre-existing
  behaviour — is silent server-side truncation: no error, no warning, just a
  model that has lost its instructions and its history. `maybe_add_tools/3`
  already drops TOOLS for models it considers too small, which produces the
  same silence from the other direction.

  Public as a test seam; called from `chat/2` and `chat_stream/3`.
  """
  @spec context_floor_error(String.t(), keyword()) :: :ok | {:error, String.t()}
  def context_floor_error(model, opts) do
    if Keyword.get(opts, :tools) in [nil, []] do
      :ok
    else
      max_ctx = OptimalSystemAgent.Providers.Registry.effective_context_window(model, :ollama)

      if is_integer(max_ctx) and max_ctx < @min_ctx_with_tools do
        ceiling = Application.get_env(:optimal_system_agent, :ollama_num_ctx, 32_768)

        cause =
          if ceiling < @min_ctx_with_tools do
            "The limit is your configured :ollama_num_ctx (#{ceiling}) — raise it to at " <>
              "least #{@min_ctx_with_tools} (config :optimal_system_agent, :ollama_num_ctx, " <>
              "#{@min_ctx_with_tools}, or OLLAMA_NUM_CTX=#{@min_ctx_with_tools})."
          else
            "The limit is the model's own trained context length as reported by " <>
              "/api/show — #{model} cannot hold a tool-using turn. Choose a model with " <>
              "at least #{@min_ctx_with_tools} tokens of context."
          end

        {:error,
         "Ollama context window for #{model} is #{max_ctx} tokens, below the " <>
           "#{@min_ctx_with_tools} needed for a turn that carries tool schemas. " <>
           "Sending it anyway would let Ollama silently truncate the prompt and drop " <>
           "the system instructions. " <> cause}
      else
        :ok
      end
    end
  end

  # Round a raw token requirement up to a standard KV-cache bucket. Floors at
  # 4096 (Ollama's own default) so we never REDUCE the window below the default.
  defp round_up_ctx(n) when n <= 4096, do: 4096
  defp round_up_ctx(n) when n <= 8192, do: 8192
  defp round_up_ctx(n) when n <= 16384, do: 16384
  defp round_up_ctx(n) when n <= 32768, do: 32768
  defp round_up_ctx(n) when n <= 65536, do: 65536
  defp round_up_ctx(_), do: 131_072

  # Keep the model resident between turns. Default 30m, overridable via
  # :ollama_keep_alive app env (OLLAMA_KEEP_ALIVE). Applied to sync AND streaming
  # bodies so a streamed turn doesn't unload the model after Ollama's 5m default
  # and pay a cold reload on the next turn.
  defp keep_alive do
    Application.get_env(:optimal_system_agent, :ollama_keep_alive, "30m")
  end

  @doc """
  Test seam: the Ollama wire shape for a list of OSA messages.
  """
  def format_messages(messages) do
    messages
    |> Enum.map(&format_message/1)
    |> demote_trailing_system()
  end

  # OSA injects `role: "system"` messages MID-conversation on purpose — the
  # task brief, background-task notifications, compaction reminders, steer
  # directives. Most chat templates render those wherever they land. Qwen 3.5's
  # embedded Jinja template does not: any system message that is not the first
  # message hits `raise_exception('System message must be at the beginning.')`,
  # and Ollama surfaces that as a 400 before generation starts. So the
  # abliterated SuperQwen GGUF answered `curl` fine and 400'd every real OSA
  # turn.
  #
  # Keep the leading system message where it is; every later one becomes a
  # user turn carrying the same text inside `<system-reminder>` tags. That is
  # the shape the harness-side reminders already use, every template accepts
  # it, and the model still reads it as an instruction rather than as chat.
  @doc false
  def demote_trailing_system([first | rest]) do
    [first | Enum.map(rest, &demote_system/1)]
  end

  def demote_trailing_system([]), do: []

  defp demote_system(%{"role" => "system", "content" => content} = msg) when is_binary(content) do
    %{
      msg
      | "role" => "user",
        "content" => "<system-reminder>\n" <> content <> "\n</system-reminder>"
    }
  end

  defp demote_system(%{"role" => "system"} = msg), do: %{msg | "role" => "user"}
  defp demote_system(msg), do: msg

  defp format_message(message) do
    case message do
      # Assistant messages that carry tool_calls must preserve them so that
      # the 2nd+ iteration has accurate conversation history.
      %{role: "assistant", tool_calls: tool_calls} = msg
      when is_list(tool_calls) and tool_calls != [] ->
        formatted_calls =
          Enum.map(tool_calls, fn tc ->
            # Read with Access, not `tc.id`. A tool call rehydrated from a
            # persisted session (`~/.osa/sessions/<id>.json`) is STRING-keyed —
            # the loader atomizes the message keys but not the nested call maps —
            # so `tc.id` raised `KeyError: key :id not found in: %{"arguments" =>
            # …, "id" => "toolu_…", "name" => "dir_list"}` and surfaced as
            # `Provider error`, killing the turn before any HTTP call. Anthropic's
            # `format_messages/1` already reads both shapes; this is the same fix.
            %{
              "id" => tc[:id] || tc["id"],
              "type" => "function",
              "function" => %{
                # `|| ""` for the same reason `arguments` has `|| %{}`: this
                # runs on rehydrated session data, and `normalize_tool_name/1`
                # raises on nil. A malformed call must not kill the turn before
                # the request is even built.
                "name" => normalize_tool_name(tc[:name] || tc["name"] || ""),
                "arguments" => tc[:arguments] || tc["arguments"] || %{}
              }
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

        # A tool result CAN be a content-block list — `ToolExecutor` builds
        # exactly that when `Read` is pointed at an image file (a text part
        # naming the path, then the image block). `to_string/1` on a list raised
        # `Protocol.UndefinedError`, which is why the Registry used to flatten
        # everything to a string before it got here.
        Map.merge(
          %{
            "role" => "tool",
            "tool_call_id" => to_string(id),
            "name" => to_string(name)
          },
          encode_content(content)
        )

      %{role: role, content: content} ->
        Map.merge(%{"role" => to_string(role)}, encode_content(content))

      %{"role" => _} = msg ->
        msg

      msg when is_map(msg) ->
        msg
    end
  end

  # Ollama's native `/api/chat` carries images as a SIBLING field of `content`:
  # `%{"role" => "user", "content" => "...", "images" => ["<base64>", ...]}` —
  # not as OpenAI-style content parts. Nothing in this module knew that, so the
  # Registry's transport gate (`transport_carries_images?/1`, which asks a
  # provider module for `supports_image_content?/0`) got no answer from Ollama,
  # answered `false`, and replaced every attached image with a placeholder
  # sentence. The placeholder was honest — but it said "OSA's integration cannot
  # send images", and the reason it could not was this function's absence.
  #
  # Whether the MODEL can see the image is a separate question and still asked
  # separately, by `ImageBudget.vision_capable?/2` in the Registry, on the same
  # fail-open terms as every other provider. This function only answers "can the
  # wire format carry it".
  @spec encode_content(term()) :: map()
  defp encode_content(blocks) when is_list(blocks) do
    {texts, images} =
      Enum.reduce(blocks, {[], []}, fn block, {texts, images} ->
        case image_data(block) do
          nil -> {[block_text(block) | texts], images}
          data -> {texts, [data | images]}
        end
      end)

    text = texts |> Enum.reverse() |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

    case Enum.reverse(images) do
      [] -> %{"content" => text}
      imgs -> %{"content" => text, "images" => imgs}
    end
  end

  defp encode_content(content), do: %{"content" => to_string(content || "")}

  # Bare base64 — Ollama takes the payload without a data: URI or a media type,
  # so the media type carried alongside it is simply not needed on this wire.
  defp image_data(%{type: t, source: %{data: data}})
       when t in ["image", :image] and is_binary(data),
       do: data

  defp image_data(%{"type" => "image", "source" => %{"data" => data}}) when is_binary(data),
    do: data

  # OpenAI-shaped parts can reach here from a rehydrated session or an MCP
  # result. Only `data:` URLs are usable: Ollama has no remote-fetch path, and
  # silently sending it an http(s) URL as if it were base64 would be a lie in the
  # request body.
  defp image_data(%{type: t, image_url: %{url: url}}) when t in ["image_url", :image_url],
    do: data_url_payload(url)

  defp image_data(%{"type" => "image_url", "image_url" => %{"url" => url}}),
    do: data_url_payload(url)

  defp image_data(_), do: nil

  defp data_url_payload("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [_media_type, data] -> data
      _ -> nil
    end
  end

  defp data_url_payload(_), do: nil

  defp block_text(%{type: t, text: text}) when t in ["text", :text] and is_binary(text), do: text
  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp block_text(text) when is_binary(text), do: text
  # A block of a shape we do not encode must not be silently deleted; rendering
  # it is worse than dropping it, so it contributes nothing to the text and the
  # Registry's image accounting stays the single place that reports a loss.
  defp block_text(_), do: ""

  @doc """
  True — the native `/api/chat` message shape carries images, see
  `encode_content/1`. Read by `Registry.transport_carries_images?/1`.
  """
  @spec supports_image_content?() :: boolean()
  def supports_image_content?, do: true

  defp maybe_add_tools(body, model, opts) do
    case Keyword.get(opts, :tools) do
      nil ->
        body

      [] ->
        body

      tools ->
        case tools_decision(model, opts) do
          {true, _source} ->
            Map.put(body, :tools, format_tools(tools))

          {false, source} ->
            report_tools_stripped(model, length(tools), source)
            body
        end
    end
  end

  # An agent with no tools cannot do anything, so this must never be a decision
  # someone has to go looking for. `:warning`, not `:debug` — and deduped per
  # process on {model, source} so a long session says it once rather than once
  # per turn.
  defp report_tools_stripped(model, count, source) do
    :telemetry.execute(
      [:osa, :ollama, :tools_stripped],
      %{tool_count: count},
      %{model: model, reason: source}
    )

    key = {model, source}

    if Process.get(:osa_ollama_tools_stripped) != key do
      Process.put(:osa_ollama_tools_stripped, key)

      Logger.warning(
        "[Ollama] #{count} tool schemas withheld from #{model} (#{source}) — this turn " <>
          "cannot call any tool. Override with OLLAMA_TOOLS=true."
      )
    end
  end

  @doc """
  Test seam: apply the `think` field decision to a request body for a model +
  opts, without a live HTTP call. Ollama has no effort→thinking wiring, so this
  must be a clean no-op (body unchanged, no `"think"` key) for a non-thinking
  model with no `:think` opt / `:ollama_think` env — regardless of effort tier
  (W4: "no thinking → clean no-op, never crash").
  """
  def apply_think(body, model, opts), do: maybe_add_think(body, model, opts)

  @doc false
  # The Ollama Cloud streaming request body. A SEAM (not inlined in
  # do_chat_stream) so the reasoning + tool decisions can be asserted directly.
  #
  # `maybe_add_think/3` was applied in `chat/2` and the LOCAL streaming path but
  # MISSING here, so every cloud reasoning model streamed with no `think` field:
  # glm-5.2 tolerated it by inlining `<think>` tags the parser strips, but
  # glm-5.3-flash's always-on reasoning jumbled into the visible answer as
  # fragmented, repetitive garbage. Building the body through this function keeps
  # the three request paths in agreement and lets a test pin that a cloud
  # reasoning model gets `think: true`.
  def build_cloud_body(model, messages, opts, tools) do
    %{
      model: model,
      messages: format_messages(messages),
      stream: true,
      keep_alive: keep_alive(),
      options: build_options(opts, messages, model)
    }
    |> apply_cloud_tools(model, opts, tools)
    |> maybe_add_think(model, opts)
  end

  defp apply_cloud_tools(body_map, model, opts, tools) do
    case {tools, tools_decision(model, opts)} do
      {[], _} ->
        body_map

      {_, {true, _source}} ->
        Map.put(body_map, :tools, format_tools(tools))

      {_, {false, source}} ->
        report_tools_stripped(model, length(tools), source)
        body_map
    end
  end

  @doc """
  Test seam: apply the tool-schema decision to a request body, without a live
  HTTP call. Withholding tools is the largest capability loss this provider can
  inflict — the agent keeps talking and stops being able to act — so it needs a
  seam that can be asserted on directly rather than only through a live turn.
  """
  def apply_tools(body, model, opts), do: maybe_add_tools(body, model, opts)

  # Controls the `think` field for Ollama reasoning models (kimi, qwen3 thinking, etc.)
  # See `reasoning_decision/2` for the rule and why it keys off SERVING MODE.
  defp maybe_add_think(body, model, opts) do
    case reasoning_decision(model, opts) do
      {nil, _source} -> body
      {val, _source} when is_boolean(val) -> Map.put(body, "think", val)
    end
  end

  @doc """
  Decide whether this request enables model reasoning, and say why.

  Returns `{true | false | nil, source}`. `nil` means **send no `think` field at
  all** — the model has no reasoning mode, so the key would be noise.

  ## Why this keys off serving mode, not capability

  The `think: false` default was introduced against a real failure: a **locally
  served** reasoning model can enter an unbounded thinking phase and stall a
  turn for 10+ minutes with no output. That guard is worth keeping.

  The bug was that it was applied via a *capability* flag (`thinking_model?/1`),
  so it also fired on `:cloud`-served models — where the stall risk is the
  provider's to manage, and the user is paying for a reasoning capability they
  then never receive. Every OSA user on a reasoning-capable Ollama Cloud model
  silently ran with reasoning OFF.

  Measured cost of running these models without reasoning: cline's published
  Terminal-Bench 2.0 run on `glm-5.2` scored **68.5% with reasoning vs 57.3%
  without** (11.2 points). A single paired local observation (n=1, confounded
  across artefacts — a hypothesis, not a result) also converged in 9 turns
  instead of 25, using 4.1x less input for 14% more output.

  ## The rule

  | condition | result | source |
  |---|---|---|
  | `opts[:think]` set | that value | `:opt` |
  | `:ollama_think` app env set (`OLLAMA_THINK`) | that value | `:config` |
  | not a reasoning model | `nil` (no field) | `:unsupported` |
  | glm cloud model (always-on reasoner), any effort | `true` | `:cloud_default` |
  | reasoning model, cloud-served, effort `:fast` | `false` | `:fast_effort` |
  | reasoning model, cloud-served, effort > `:fast` | `true` | `:cloud_default` |
  | reasoning model, locally served | `false` | `:local_stall_guard` |

  Both explicit routes override in BOTH directions and for BOTH serving modes:
  `OLLAMA_THINK=false` still disables a cloud model, `OLLAMA_THINK=true` still
  enables a local one (accepting the stall risk knowingly).

  The value is constant for a given model + configuration, so it does not vary
  turn-to-turn within a session; and it is a request-body field rather than
  prompt content, so it cannot perturb a cached prompt prefix either way.
  """
  @spec reasoning_decision(String.t() | nil, keyword()) ::
          {boolean() | nil,
           :opt | :config | :unsupported | :cloud_default | :fast_effort | :local_stall_guard}
  def reasoning_decision(model, opts \\ []) do
    cond do
      is_boolean(val = Keyword.get(opts, :think)) ->
        {val, :opt}

      is_boolean(cfg = Application.get_env(:optimal_system_agent, :ollama_think)) ->
        {cfg, :config}

      not thinking_model?(model) ->
        {nil, :unsupported}

      # glm cloud models reason ALWAYS-ON. With think:false they do not emit the
      # native `thinking` field, so their chain-of-thought spills into `content`
      # and renders as the visible answer (the reported "whole monologue on
      # screen"). Keep think:true so reasoning is routed to the collapsible
      # thinking channel instead of leaking - even on :fast, where the flash
      # model is already fast enough that the reasoning phase is cheap.
      cloud_model?(model) and always_on_reasoner?(model) ->
        {true, :cloud_default}

      cloud_model?(model) ->
        # Effort steers reasoning on cloud models too. With no explicit opt and
        # no OLLAMA_THINK config (both checked above and still overriding both
        # ways), consult the current effort: :fast asks for a quick, concise
        # turn, so disable the extra reasoning phase; any higher effort keeps the
        # cloud default of think:true. Default effort is :medium, so the
        # non-fast default is unchanged.
        case OptimalSystemAgent.Agent.Effort.current() do
          :fast -> {false, :fast_effort}
          _ -> {true, :cloud_default}
        end

      true ->
        # Locally served reasoning model: keep the guard against unbounded
        # thinking phases. Opt in with OLLAMA_THINK=true.
        {false, :local_stall_guard}
    end
  end

  @doc """
  True when `model` is served by Ollama Cloud rather than by local weights.

  The discriminator is the hosted TAG SHAPE — a bare `":cloud"` tag
  (`glm-5.2:cloud`) or a size-qualified `"-cloud"` suffix
  (`gpt-oss:120b-cloud`) — via `OllamaCloud.cloud_tag?/1`, which is the same
  predicate `Registry.ollama_cloud_model?/1` already uses to decide context-window
  probing and the local `num_ctx` clamp. It is a naming convention Ollama itself
  imposes on hosted tags, not an OSA invention, and it is already load-bearing
  elsewhere in this codebase — so a model that lies about it is already
  mis-budgeted regardless of this call. It is not a live server probe: a
  `/api/show` round trip cannot be afforded on the request path, and an
  unreachable daemon would have to fall back to the tag shape anyway.

  A false negative is safe (a cloud model mistagged as local merely keeps the
  old, conservative behaviour). A false positive costs a possible stall on a
  local model, recoverable with `OLLAMA_THINK=false`.
  """
  @spec cloud_model?(String.t() | nil) :: boolean()
  def cloud_model?(model), do: OptimalSystemAgent.Providers.OllamaCloud.cloud_tag?(model)

  # Models whose reasoning is ALWAYS-ON: they reason regardless of `think`, so
  # `think: false` does not save time - it only removes the native `thinking`
  # channel, spilling the chain-of-thought into `content` (a visible-answer
  # leak). For these we keep `think: true` even on :fast so reasoning stays in
  # the collapsible thinking channel. glm-5.x is the known family.
  @spec always_on_reasoner?(String.t() | nil) :: boolean()
  defp always_on_reasoner?(model) when is_binary(model),
    do: String.contains?(String.downcase(model), "glm")

  defp always_on_reasoner?(_), do: false

  # Returns true for models known to enter unbounded thinking phases by default.
  @doc false
  def thinking_model?(model_name) do
    # OllamaCloud first — same reason as `model_supports_tools?/1`: its
    # `thinking` flags came from the daemon's `capabilities`, so reasoning
    # models whose names miss the heuristic (gemma4, glm, minimax, qwen3.5,
    # nemotron, gpt-oss) are still driven with `think: true`.
    case OptimalSystemAgent.Providers.OllamaCloud.capability(model_name, :thinking) do
      true ->
        true

      false ->
        false

      nil ->
        case OptimalSystemAgent.Providers.ModelLimits.reasoning(:ollama, model_name) do
          true -> true
          false -> false
          _ -> heuristic_thinking_model?(model_name)
        end
    end
  end

  # Reasoning-model name heuristic used when the Catalog has no reasoning flag.
  # Broadened past kimi/'thinking' to the common local reasoning tags whose names
  # don't literally contain 'thinking' (deepseek-r1, qwq, qwen '-r1' variants).
  # `reasoning_decision/2` advertises `String.t() | nil`, and every layer above
  # honoured the `nil` right up to here, where `String.downcase/1` raised. A
  # nameless model is not evidence of a reasoning phase — the honest answer is
  # "no", not an exception out of a capability query.
  defp heuristic_thinking_model?(nil), do: false

  defp heuristic_thinking_model?(model_name) do
    name = String.downcase(model_name)

    String.contains?(name, "thinking") or
      String.starts_with?(name, "kimi") or
      String.contains?(name, "deepseek-r1") or
      String.contains?(name, "qwq") or
      String.contains?(name, "-r1")
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
          [
            %{
              id: call["id"] || generate_id(),
              name: normalize_tool_name(name),
              arguments: Map.get(func, "arguments", %{})
            }
          ]

        %{"name" => name} ->
          [
            %{
              id: call["id"] || generate_id(),
              name: normalize_tool_name(name),
              arguments: call["arguments"] || %{}
            }
          ]

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

  # WS1 (Grok dual idle-timeout): bump the llm_client idle-watchdog atomic passed
  # in via `opts[:heartbeat]`. Called from BOTH streaming receive points — the
  # cloud curl port and the local Finch `into:` reader — on every raw chunk
  # BEFORE parsing, so the watchdog resets on ANY bytes flowing, not only on
  # parsed stream events, and the idle timeout fires only on a genuinely silent
  # socket. Same `:atomics.add/3` reset the llm_client `:text_delta` arm uses.
  # `nil` (no agent-loop watchdog, e.g. a direct provider unit test) is a no-op.
  defp bump_heartbeat(nil), do: :ok
  defp bump_heartbeat(heartbeat), do: :atomics.add(heartbeat, 1, 1)

  defp handle_stream_chunk(data, callback, acc) do
    {lines, new_buffer} = split_ndjson(acc.buffer <> data)
    acc = %{acc | buffer: new_buffer}
    Enum.reduce(lines, acc, &process_ndjson_line(&1, callback, &2))
  end

  defp finalize_stream(acc, callback) do
    flush_think(acc, callback)
    content = Text.strip_thinking_tokens(acc.content)

    tool_calls =
      if acc.tool_calls != [],
        do: acc.tool_calls,
        else: ToolCallParsers.parse(acc.content, "ollama")

    # Pass through usage captured from the done:true chunk (prompt_eval_count/eval_count).
    # Keys already normalised to :input_tokens/:output_tokens by process_ndjson_line.
    # `stop_reason` comes from the same chunk's `done_reason` — "length" means
    # the model was cut off at `num_predict`, which the loop must never deliver
    # as a final answer.
    callback.(
      {:done,
       %{
         content: content,
         tool_calls: tool_calls,
         usage: acc.usage,
         stop_reason: Map.get(acc, :stop_reason)
       }}
    )

    :ok
  end

  # Drain any partial reasoning-tag tail the streaming splitter is holding so
  # trailing characters are never dropped from the live display.
  defp flush_think(acc, callback) do
    case Map.get(acc, :think) do
      %ThinkStreamParser{} = ts ->
        {leftover_vis, leftover_think, _} = ThinkStreamParser.flush(ts)
        if leftover_think != "", do: callback.({:thinking_delta, leftover_think})
        if leftover_vis != "", do: callback.({:text_delta, leftover_vis})

      _ ->
        :ok
    end
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
      # A SINGLE chunk carrying BOTH native reasoning AND visible content. The
      # content-only arm below would otherwise match first and DROP the
      # `thinking` field (native reasoning lost). Emit reasoning to the thinking
      # box, then run the content through the SAME ThinkStreamParser path so
      # neither channel is lost. Mirrors `cloud_stream_loop/3`, so the local and
      # cloud paths agree on a both-present chunk.
      {:ok, %{"message" => %{"thinking" => think_text, "content" => text}}}
      when is_binary(think_text) and think_text != "" and
             is_binary(text) and text != "" ->
        callback.({:thinking_delta, think_text})
        text = Mojibake.repair(text)

        case Map.get(acc, :think) do
          %ThinkStreamParser{} = ts ->
            {visible, thinking, think_state} = ThinkStreamParser.feed(ts, text)
            if thinking != "", do: callback.({:thinking_delta, thinking})
            if visible != "", do: callback.({:text_delta, visible})
            %{acc | content: acc.content <> text, think: think_state}

          _ ->
            callback.({:text_delta, text})
            %{acc | content: acc.content <> text}
        end

      {:ok, %{"message" => %{"content" => text}}} when is_binary(text) and text != "" ->
        text = Mojibake.repair(text)

        # Split inline <think>…</think> reasoning out before emitting so the
        # tags + reasoning never leak into the visible answer.
        case Map.get(acc, :think) do
          %ThinkStreamParser{} = ts ->
            {visible, thinking, think_state} = ThinkStreamParser.feed(ts, text)
            if thinking != "", do: callback.({:thinking_delta, thinking})
            if visible != "", do: callback.({:text_delta, visible})
            %{acc | content: acc.content <> text, think: think_state}

          _ ->
            callback.({:text_delta, text})
            %{acc | content: acc.content <> text}
        end

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
                [
                  %{
                    id: call["id"] || generate_id(),
                    name: normalize_tool_name(name),
                    arguments: Map.get(func, "arguments", %{})
                  }
                ]

              %{"name" => name} ->
                [
                  %{
                    id: call["id"] || generate_id(),
                    name: normalize_tool_name(name),
                    arguments: call["arguments"] || %{}
                  }
                ]

              _ ->
                Logger.warning(
                  "[Ollama] Skipping malformed streaming tool_call: #{inspect(call)}"
                )

                []
            end
          end)

        %{acc | tool_calls: acc.tool_calls ++ tool_calls}

      # Final chunk — capture usage stats so context pressure reports correctly.
      # Keys normalised to :input_tokens/:output_tokens to match what loop.ex reads.
      # Only add usage when at least one token count is present — some done chunks
      # (e.g. {"done":true,"done_reason":"stop"} with no eval fields) carry no counts.
      {:ok, %{"done" => true} = resp} ->
        input = resp["prompt_eval_count"] || 0
        output = resp["eval_count"] || 0

        # Terminal stop reason. Captured UNCONDITIONALLY — independently of the
        # token counts, because a done chunk may carry `done_reason` with no
        # eval fields at all, and "why did it stop" is the more important of
        # the two facts. `Map.put` rather than `%{acc | ...}` so an older acc
        # shape (no `:stop_reason` key) still works.
        acc =
          case resp["done_reason"] do
            r when is_binary(r) and r != "" -> Map.put(acc, :stop_reason, r)
            _ -> acc
          end

        if input > 0 or output > 0 do
          usage = %{input_tokens: input, output_tokens: output, total_tokens: input + output}
          %{acc | usage: usage}
        else
          acc
        end

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

  # IDLE timeout: the longest gap allowed BETWEEN streamed chunks.
  #
  # Finch defines `:receive_timeout` as "the maximum time to wait for each chunk to
  # be received" — it is reset by every chunk, and is NOT a cap on total request
  # duration (that would be `:request_timeout`, which OSA deliberately does not
  # set). So a turn that keeps producing output can stream for hours; only genuine
  # silence trips this.
  #
  # That makes the correct value SMALL, not large. It was briefly set to 4 h here
  # while being mistaken for a total-duration cap — which would have meant waiting
  # four hours to notice a dead socket. 5 minutes matches Codex's
  # `stream_idle_timeout_ms = 300_000` and is the same reasoning: long healthy
  # turns are never killed, wedged connections surface promptly.
  #
  # Override with OLLAMA_TIMEOUT_MS (falls back to the default if unparseable).
  @default_receive_timeout_ms 300_000
  defp receive_timeout_ms do
    case System.get_env("OLLAMA_TIMEOUT_MS") do
      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {ms, _} when ms > 0 -> ms
          _ -> @default_receive_timeout_ms
        end

      _ ->
        @default_receive_timeout_ms
    end
  end

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
