defmodule OptimalSystemAgent.Providers.RegistryHopSyncDuplicateTest do
  @moduledoc """
  The one-way door has a second side entrance.

  `stream_with_fallback/5` consults `Resilience.output_observed?/0` before it
  drops to `fallback_sync_stream/4` — that hole is closed and pinned by
  `registry_stream_fallback_suppression_test.exs`.

  But the PER-HOP path did not. When the primary fails with nothing on screen
  the chain proceeds, and each hop goes through `try_stream_provider/4` →
  `do_try_stream_provider/4`, which on `{:error, _}` (or a raise) called
  `fallback_sync_stream/4` unconditionally. `fallback_sync_stream/4` pushes the
  WHOLE sync response through the live callback as one `:text_delta` — there is
  no `emitted` cursor. So a fallback hop that streamed 80% and then died
  rendered that 80% followed by 100% of the answer, and the duplicate is what
  gets appended as the assistant turn and persisted into the next request's
  prefix.

  Two pins here:
    * a hop that streamed before failing must not sync-retry into the same
      callback, and
    * the chain must not advance to a LATER hop after a hop put bytes on
      screen, since the next hop re-streams the answer from scratch.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry
  alias OptimalSystemAgent.Providers.Resilience

  @port_base 21_900

  setup do
    # `stream_capable?/1` is `function_exported?(module, :chat_stream, 3)`,
    # which answers FALSE for a module that has not been loaded yet.
    Code.ensure_loaded!(OptimalSystemAgent.Providers.Anthropic)

    {:ok, collector} = Agent.start_link(fn -> [] end)

    window = @port_base + rem(System.unique_integer([:positive]), 200) * 4

    # Primary (:openai, a {:compat, _} target): fails IMMEDIATELY with a
    # transient 503 and never emits. Nothing reaches the user, so the chain is
    # allowed to proceed — this test is about what happens on the HOP.
    {primary_srv, primary_port} = start_stub(window, collector, 0, :silent_503)

    # Hop (:anthropic, a plain module target — the `do_try_stream_provider/4`
    # clause that owns the bug): streams one visible delta then dies
    # mid-stream, and answers the follow-up NON-streaming request with a
    # complete 200. On the original code that 200 was pushed through the same
    # live callback in full.
    {hop_srv, hop_port} = start_stub(window + 2, collector, 0, :die_then_succeed_sync)

    prev =
      snapshot([
        :anthropic_url,
        :anthropic_api_key,
        :openai_url,
        :openai_api_key,
        :fallback_chain,
        :default_provider
      ])

    prev_retries = System.get_env("OSA_API_MAX_RETRIES")
    System.put_env("OSA_API_MAX_RETRIES", "0")

    put(:openai_url, "http://127.0.0.1:#{primary_port}/v1")
    put(:openai_api_key, "sk-test-not-a-real-key")
    put(:anthropic_url, "http://127.0.0.1:#{hop_port}/v1")
    put(:anthropic_api_key, "sk-ant-test-not-a-real-key")

    # `stream_fallback_chain/5` drops the failed provider TWICE (drop_while,
    # then the `[_ | rest] -> rest` clause), so the entry immediately after the
    # failed one is always skipped. With :openai failing, this leaves exactly
    # [:anthropic]. That double-drop is pre-existing behaviour, not something
    # this change touches; encoding it keeps the fixture honest.
    put(:fallback_chain, [:openai, :ollama, :anthropic])
    put(:default_provider, :openai)

    on_exit(fn ->
      restore_all(prev)

      if prev_retries,
        do: System.put_env("OSA_API_MAX_RETRIES", prev_retries),
        else: System.delete_env("OSA_API_MAX_RETRIES")

      Process.exit(primary_srv, :kill)
      Process.exit(hop_srv, :kill)
    end)

    {:ok, collector: collector}
  end

  defp events(collector), do: collector |> Agent.get(& &1) |> Enum.reverse()

  defp deltas(collector), do: for({:delta, text} <- events(collector), do: text)

  defp hop_hits(collector), do: for({:hit, :hop, kind} <- events(collector), do: kind)

  # Mirrors `Agent.Loop.LLMClient`: the renderer marks the door on the first
  # visible byte, and the registry is required to consult it.
  defp observing_callback(collector) do
    fn
      {:text_delta, text} ->
        Resilience.mark_output_observed()
        Agent.update(collector, &[{:delta, text} | &1])
        :ok

      _ ->
        :ok
    end
  end

  defp messages, do: [%{role: "user", content: "hello"}]

  describe "a fallback hop that streamed before failing" do
    test "does not re-push the whole answer through the same callback", %{collector: c} do
      Registry.chat_stream(messages(), observing_callback(c), provider: :openai, max_tokens: 64)

      seen = deltas(c)

      assert seen != [],
             "precondition: the hop must actually have streamed something visible " <>
               "(hop hits: #{inspect(hop_hits(c))})"

      assert length(seen) == 1,
             "fallback_sync_stream/4 emits the ENTIRE sync body as one :text_delta with no " <>
               "cursor for what was already sent — the user watched the answer twice " <>
               "(got: #{inspect(seen)})"
    end

    test "does not issue a same-provider sync request at all", %{collector: c} do
      Registry.chat_stream(messages(), observing_callback(c), provider: :openai, max_tokens: 64)

      assert :stream in hop_hits(c), "precondition: the hop must have been streamed"

      refute :sync in hop_hits(c),
             "past the one-way door the only honest options are finish or fail; a sync " <>
               "re-request exists only to be re-emitted (hits: #{inspect(hop_hits(c))})"
    end

    test "surfaces the failure instead of a duplicated success", %{collector: c} do
      assert {:error, _} =
               Registry.chat_stream(messages(), observing_callback(c),
                 provider: :openai,
                 max_tokens: 64
               )
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp put(key, value), do: Application.put_env(:optimal_system_agent, key, value)

  defp snapshot(keys),
    do: Map.new(keys, fn k -> {k, Application.fetch_env(:optimal_system_agent, k)} end)

  defp restore_all(prev) do
    Enum.each(prev, fn
      {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
      {k, :error} -> Application.delete_env(:optimal_system_agent, k)
    end)
  end

  defp start_stub(_base, _pid, attempt, _mode) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, collector, attempt, mode) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.StubPlug, {collector, mode}},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, collector, attempt + 1, mode)
    end
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(state), do: state

    # Primary: a clean transient 503 with no body content ever streamed.
    def call(conn, {collector, :silent_503}) do
      {:ok, _raw, conn} = read_body(conn)
      Agent.update(collector, &[{:hit, :primary, conn.request_path} | &1])

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        503,
        Jason.encode!(%{"error" => %{"type" => "overloaded_error", "message" => "Overloaded"}})
      )
    end

    def call(conn, {collector, :die_then_succeed_sync}) do
      {:ok, raw, conn} = read_body(conn)
      streaming? = String.contains?(raw, "\"stream\":true")

      Agent.update(
        collector,
        &[{:hit, :hop, if(streaming?, do: :stream, else: :sync)} | &1]
      )

      if streaming? do
        body =
          sse("message_start", message_start()) <>
            sse("content_block_start", content_block_start()) <>
            sse("content_block_delta", text_delta()) <>
            sse("error", error_event())

        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {:ok, conn} = chunk(conn, body)
        conn
      else
        # The sync re-request the buggy path made. Answering it with a healthy
        # 200 is what turned a partial answer into a doubled one.
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, whole_answer_body())
      end
    end

    defp sse(event, data), do: "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"

    defp message_start do
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_stub",
          "type" => "message",
          "role" => "assistant",
          "content" => [],
          "model" => "stub",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 0}
        }
      }
    end

    defp content_block_start do
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }
    end

    defp text_delta do
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "the first 80% of the answer"}
      }
    end

    defp error_event do
      %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded mid-stream"}
      }
    end

    defp whole_answer_body do
      Jason.encode!(%{
        "id" => "msg_stub_sync",
        "type" => "message",
        "role" => "assistant",
        "model" => "stub",
        "content" => [
          %{"type" => "text", "text" => "the first 80% of the answer plus the last 20%"}
        ],
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })
    end
  end
end
