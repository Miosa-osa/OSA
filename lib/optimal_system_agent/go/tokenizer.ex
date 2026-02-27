defmodule OptimalSystemAgent.Go.Tokenizer do
  @moduledoc """
  GenServer wrapping a Go tokenizer process for accurate BPE token counting.

  Falls back to a heuristic (words * 1.3 + punct * 0.5) when the Go binary
  is unavailable. The binary is expected at:
    1. priv/go/tokenizer/osa-tokenizer (in-tree, for dev)
    2. ~/.osa/bin/osa-tokenizer (installed)
  """
  use GenServer
  require Logger

  @behaviour OptimalSystemAgent.Sidecar.Behaviour

  alias OptimalSystemAgent.Sidecar.{Protocol, Registry}

  @request_timeout 2_000
  @cache_table :osa_token_cache
  # 5 minutes
  @cache_ttl_ms 300_000

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # -- Sidecar.Behaviour callbacks --

  @impl OptimalSystemAgent.Sidecar.Behaviour
  def call(method, params, timeout \\ @request_timeout) do
    GenServer.call(__MODULE__, {:request, method, params}, timeout + 500)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @impl OptimalSystemAgent.Sidecar.Behaviour
  def health_check do
    if Process.whereis(__MODULE__) == nil do
      :unavailable
    else
      case GenServer.call(__MODULE__, :health, 2_000) do
        :ready -> :ready
        :fallback -> :degraded
        _ -> :unavailable
      end
    end
  catch
    :exit, _ -> :unavailable
  end

  @impl OptimalSystemAgent.Sidecar.Behaviour
  def capabilities, do: [:tokenization]

  @doc "Count tokens in text. Returns {:ok, count} or {:error, reason}."
  @spec count_tokens(String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def count_tokens(text) when is_binary(text) do
    # Fast path: if GenServer isn't running, skip to heuristic
    if Process.whereis(__MODULE__) == nil do
      {:ok, count_tokens_heuristic(text)}
    else
      cache_key = :erlang.phash2(text)

      case lookup_cache(cache_key) do
        {:ok, count} ->
          {:ok, count}

        :miss ->
          case GenServer.call(__MODULE__, {:count_tokens, text}, @request_timeout + 500) do
            {:ok, count} = result ->
              put_cache(cache_key, count)
              result

            error ->
              error
          end
      end
    end
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc "Count tokens using heuristic (no Go binary needed)."
  @spec count_tokens_heuristic(String.t()) :: non_neg_integer()
  def count_tokens_heuristic(text),
    do: OptimalSystemAgent.Utils.Tokens.estimate(text)

  @doc "Check if the Go tokenizer is available (not in fallback mode)."
  @spec available?() :: boolean()
  def available? do
    GenServer.call(__MODULE__, :available?)
  catch
    :exit, _ -> false
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    ensure_cache_table()
    binary_path = find_binary()

    state = %{
      port: nil,
      mode: :fallback,
      binary_path: binary_path,
      # id => {from, timer_ref}
      pending: %{}
    }

    state = maybe_start_port(state)

    # Register with sidecar registry
    Registry.register(__MODULE__, capabilities())
    Registry.update_health(__MODULE__, if(state.mode == :ready, do: :ready, else: :degraded))

    if state.mode == :ready do
      Logger.info("[Go.Tokenizer] Started with binary at #{binary_path}")
    else
      Logger.info("[Go.Tokenizer] Running in fallback mode (heuristic)")
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:count_tokens, text}, _from, %{mode: :fallback} = state) do
    {:reply, {:ok, count_tokens_heuristic(text)}, state}
  end

  def handle_call({:count_tokens, text}, from, %{mode: :ready, port: port} = state) do
    {id, encoded} = Protocol.encode_request("count_tokens", %{"text" => text})
    Port.command(port, encoded)

    timer_ref = Process.send_after(self(), {:request_timeout, id}, @request_timeout)
    pending = Map.put(state.pending, id, {from, timer_ref})

    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_call(:available?, _from, state) do
    {:reply, state.mode == :ready, state}
  end

  def handle_call(:health, _from, state) do
    {:reply, state.mode, state}
  end

  # Generic request handler for Sidecar.Behaviour compatibility
  def handle_call({:request, "count_tokens", %{"text" => text}}, from, state) do
    handle_call({:count_tokens, text}, from, state)
  end

  def handle_call({:request, _method, _params}, _from, state) do
    {:reply, {:error, :unsupported_method}, state}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Protocol.decode_response(line) do
      {:ok, id, %{"count" => count}} when is_integer(count) ->
        resolve_pending(state, id, {:ok, count})

      {:ok, id, result} ->
        # Try to extract count from result
        count = Map.get(result, "count", 0)
        resolve_pending(state, id, {:ok, count})

      {:error, id, _error} when is_binary(id) ->
        resolve_pending(state, id, {:error, :sidecar_error})

      {:error, :invalid, reason} ->
        Logger.warning("[Go.Tokenizer] Invalid response: #{reason}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[Go.Tokenizer] Port exited with status #{status}, switching to fallback")

    # Fail all pending requests
    state = fail_all_pending(state, :port_crashed)

    # Try to restart after a delay
    Process.send_after(self(), :restart_port, 5_000)

    {:noreply, %{state | port: nil, mode: :fallback}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer_ref}, pending} ->
        # fallback to 0 on timeout
        GenServer.reply(from, {:ok, 0})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(:restart_port, state) do
    state = maybe_start_port(%{state | port: nil})

    if state.mode == :ready do
      Logger.info("[Go.Tokenizer] Port restarted successfully")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = _state) when not is_nil(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Private --

  defp maybe_start_port(%{binary_path: nil} = state), do: state

  defp maybe_start_port(%{binary_path: path} = state) do
    if File.exists?(path) do
      try do
        port =
          Port.open(
            {:spawn_executable, path},
            [:binary, :use_stdio, :exit_status, {:line, 1_048_576}]
          )

        %{state | port: port, mode: :ready}
      rescue
        e ->
          Logger.warning("[Go.Tokenizer] Failed to start port: #{inspect(e)}")
          state
      end
    else
      state
    end
  end

  defp find_binary do
    # Check in-tree first, then installed location
    priv_path =
      Path.join([
        :code.priv_dir(:optimal_system_agent) |> to_string(),
        "go",
        "tokenizer",
        "osa-tokenizer"
      ])

    installed_path = Path.expand("~/.osa/bin/osa-tokenizer")

    cond do
      File.exists?(priv_path) -> priv_path
      File.exists?(installed_path) -> installed_path
      true -> nil
    end
  end

  defp resolve_pending(state, id, result) do
    case Map.pop(state.pending, id) do
      {{from, timer_ref}, pending} ->
        Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer_ref}} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  # -- ETS Cache --

  defp ensure_cache_table do
    case :ets.info(@cache_table) do
      :undefined ->
        :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp lookup_cache(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, count, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at < @cache_ttl_ms do
          {:ok, count}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  rescue
    _ -> :miss
  end

  defp put_cache(key, count) do
    :ets.insert(@cache_table, {key, count, System.monotonic_time(:millisecond)})
  rescue
    _ -> :ok
  end
end
