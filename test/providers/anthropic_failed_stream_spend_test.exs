defmodule OptimalSystemAgent.Providers.AnthropicFailedStreamSpendTest do
  @moduledoc """
  A stream that dies mid-flight was already paid for.

  Anthropic delivers the ENTIRE prompt cost in `message_start` — `input_tokens`
  plus both cache slices — before a single output token exists. Every failure
  exit below that point returns `{:error, {:stream_error, reason, partial}}`,
  which preserves partial CONTENT and drops `acc.usage` on the floor. The loop
  then sets `usage = %{}`, correctly, for what it was handed. On a long-prompt
  turn the prompt IS the bill, so this silently lost most of the money on every
  failed request.

  The fix does not widen the error tuple (its shape is pattern-matched at six
  plus sites across the loop and the retry classifier). The provider STAGES the
  usage into `Accounting`'s side ledger keyed on session id — the same
  stage/absorb vehicle compaction spend already uses — and the loop absorbs it
  at the point it holds both state and session id.

  Everything here runs against a local Bandit stub on 127.0.0.1. No request
  leaves the machine and no real provider is contacted.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Loop.Accounting
  alias OptimalSystemAgent.Providers.Anthropic

  @port_base 19_660

  # A big prompt is admitted, then the stream dies. This is the shape that
  # costs real money: 41_000 fresh input + 120_000 cache-read, zero output.
  @failing_sse [
                 ~s(event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":41000,"output_tokens":0,"cache_creation_input_tokens":2000,"cache_read_input_tokens":120000}}}\n\n),
                 ~s(event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n),
                 ~s(event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial "}}\n\n),
                 ~s(event: error\ndata: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}\n\n)
               ]
               |> Enum.join()

  # A request rejected before generation starts: no `message_start`, so there
  # is genuinely nothing to bill. Closed explicitly rather than by accident.
  @pregen_sse ~s(event: error\ndata: {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}\n\n)

  setup do
    Code.ensure_loaded!(Anthropic)
    Code.ensure_loaded!(Accounting)

    prev = snapshot([:anthropic_url, :anthropic_api_key, :anthropic_model])

    Application.put_env(:optimal_system_agent, :anthropic_api_key, "sk-ant-test-not-a-real-key")

    session_id = "failed-stream-#{System.unique_integer([:positive])}"
    Accounting.forget_side_spend(session_id)

    on_exit(fn ->
      restore_all(prev)
      Accounting.forget_side_spend(session_id)
    end)

    {:ok, session_id: session_id}
  end

  describe "a stream that fails after message_start" do
    test "still bills the prompt it already paid for", %{session_id: sid} do
      srv = point_at_stub(@failing_sse)
      on_exit(fn -> Process.exit(srv, :kill) end)

      result =
        Anthropic.chat_stream(
          [%{role: "user", content: "hi"}],
          fn _ -> :ok end,
          model: "claude-sonnet-4-5-20250929",
          session_id: sid
        )

      # The error tuple's shape is UNCHANGED — that is the point of routing the
      # usage around it rather than through it.
      assert {:error, {:stream_error, reason, partial}} = result
      assert is_binary(reason)
      assert partial == "partial "

      staged = Accounting.peek_side_spend(sid)

      assert staged != nil,
             "the failed request billed nothing — acc.usage was dropped on the error path"

      assert staged.usage.input_tokens == 41_000
      assert staged.usage.cache_creation_input_tokens == 2_000
      assert staged.usage.cache_read_input_tokens == 120_000
      assert staged.usage.output_tokens == 0

      # Priced, not merely counted. A 163k-token prompt is not free.
      assert staged.cost_usd > 0.0
      assert staged.calls == 1
      assert :failed_request in staged.kinds
    end

    test "reconciliation runs exactly once, and is a no-op for Anthropic's wire shape",
         %{session_id: sid} do
      srv = point_at_stub(@failing_sse)
      on_exit(fn -> Process.exit(srv, :kill) end)

      Anthropic.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end,
        model: "claude-sonnet-4-5-20250929",
        session_id: sid
      )

      staged = Accounting.peek_side_spend(sid)

      # `reconcile_prompt_slices/2` subtracts the cached overlap out of
      # `input_tokens` for INCLUSIVE providers only. Anthropic is disjoint, so
      # `input_tokens` must survive untouched. If this ever reads 41_000 minus
      # 122_000 clamped to 0, the provider tag was lost and the fresh input is
      # being thrown away.
      assert staged.usage.input_tokens == 41_000
    end

    test "each retried attempt is billed, because each attempt is separately charged",
         %{session_id: sid} do
      srv = point_at_stub(@failing_sse)
      on_exit(fn -> Process.exit(srv, :kill) end)

      for _ <- 1..3 do
        Anthropic.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end,
          model: "claude-sonnet-4-5-20250929",
          session_id: sid
        )
      end

      staged = Accounting.peek_side_spend(sid)
      assert staged.calls == 3
      assert staged.usage.input_tokens == 123_000
    end

    test "the staged spend moves onto the session's own counters when absorbed",
         %{session_id: sid} do
      srv = point_at_stub(@failing_sse)
      on_exit(fn -> Process.exit(srv, :kill) end)

      Anthropic.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end,
        model: "claude-sonnet-4-5-20250929",
        session_id: sid
      )

      state = %{
        session_id: sid,
        provider: :anthropic,
        model: "claude-sonnet-4-5-20250929",
        session_cost_usd: 0.0,
        session_input_tokens: 0,
        session_output_tokens: 0,
        session_cache_creation_tokens: 0,
        session_cache_read_tokens: 0
      }

      absorbed = Accounting.absorb_side_spend(state)

      assert absorbed.session_input_tokens == 41_000
      assert absorbed.session_cache_read_tokens == 120_000
      assert absorbed.session_cost_usd > 0.0

      # The ledger row is CONSUMED, so the loop absorbing on every turn cannot
      # bill the same failure twice.
      assert Accounting.peek_side_spend(sid) == nil
      again = Accounting.absorb_side_spend(absorbed)
      assert again.session_input_tokens == 41_000
      assert again.session_cost_usd == absorbed.session_cost_usd
    end

    test "does NOT move last_input_tokens — a dead request is not the context size",
         %{session_id: sid} do
      srv = point_at_stub(@failing_sse)
      on_exit(fn -> Process.exit(srv, :kill) end)

      Anthropic.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end,
        model: "claude-sonnet-4-5-20250929",
        session_id: sid
      )

      state = %{session_id: sid, provider: :anthropic, model: "claude-sonnet-4-5-20250929"}
      absorbed = Accounting.absorb_side_spend(state)

      refute Map.get(absorbed, :last_input_tokens) == 161_000
    end
  end

  describe "a request that fails BEFORE generation" do
    test "stages nothing, because it genuinely cost nothing", %{session_id: sid} do
      srv = point_at_stub(@pregen_sse)
      on_exit(fn -> Process.exit(srv, :kill) end)

      Anthropic.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end,
        model: "claude-sonnet-4-5-20250929",
        session_id: sid
      )

      assert Accounting.peek_side_spend(sid) == nil,
             "an error before message_start has an all-zero usage map and must " <>
               "not create a ledger row"
    end

    test "a transport failure that never reaches the provider stages nothing",
         %{session_id: sid} do
      Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:1/v1")

      assert {:error, _} =
               Anthropic.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end,
                 model: "claude-sonnet-4-5-20250929",
                 session_id: sid
               )

      assert Accounting.peek_side_spend(sid) == nil
    end
  end

  describe "a stream with no session identity" do
    test "fails safely rather than crashing the request" do
      srv = point_at_stub(@failing_sse)
      on_exit(fn -> Process.exit(srv, :kill) end)

      # No `:session_id` in opts — nothing to bill against. The request must
      # still return its normal error rather than raising inside billing.
      assert {:error, {:stream_error, _, _}} =
               Anthropic.chat_stream([%{role: "user", content: "hi"}], fn _ -> :ok end,
                 model: "claude-sonnet-4-5-20250929"
               )
    end
  end

  # ── stub ────────────────────────────────────────────────────────────────

  defp point_at_stub(sse) do
    window = @port_base + rem(System.unique_integer([:positive]), 100) * 2
    {srv, port} = start_stub(window, sse, 0)
    Application.put_env(:optimal_system_agent, :anthropic_url, "http://127.0.0.1:#{port}/v1")
    srv
  end

  defp snapshot(keys),
    do: Map.new(keys, fn k -> {k, Application.fetch_env(:optimal_system_agent, k)} end)

  defp restore_all(prev) do
    Enum.each(prev, fn
      {k, {:ok, v}} -> Application.put_env(:optimal_system_agent, k, v)
      {k, :error} -> Application.delete_env(:optimal_system_agent, k)
    end)
  end

  defp start_stub(_base, _sse, attempt) when attempt > 20,
    do: flunk("could not bind a stub HTTP port after 20 attempts")

  defp start_stub(base, sse, attempt) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.DyingStreamPlug, %{sse: sse}},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, sse, attempt + 1)
    end
  end

  defmodule DyingStreamPlug do
    @moduledoc """
    A 200 OK event stream that admits the prompt and then reports an error
    event. The connection was never an HTTP failure — that is exactly why the
    usage it already reported is real, and exactly why it used to be lost.
    """
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, %{sse: sse}) do
      {:ok, _raw, conn} = read_body(conn)

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, sse)
    end
  end
end
