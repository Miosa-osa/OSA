defmodule OptimalSystemAgent.Providers.RegistryStreamFallbackSuppressionTest do
  @moduledoc """
  Delivering bytes to the user is a one-way door.

  `Resilience.do_retry/7` already honours it: once `mark_output_observed/0`
  has fired, a same-provider retry is refused, because a retry re-invokes the
  provider against the SAME live callback and every token already on screen
  would be emitted a second time.

  `stream_with_fallback/5` was the side entrance. It received that
  deliberately-unretried error and immediately did the very thing the retry
  suppression existed to prevent: a same-provider SYNC attempt that pushes the
  whole response through the same callback, and failing that a provider chain
  that re-streams from scratch. The user watched a partial paragraph, then the
  full answer again.

  Past the door the only honest options are "finish" or "fail".
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.Registry
  alias OptimalSystemAgent.Providers.Resilience

  @port_base 21_400

  setup do
    # `Registry.stream_capable?/1` is `function_exported?(module, :chat_stream, 3)`,
    # which answers FALSE for a module that has not been loaded yet. On a cold
    # VM the first call therefore took the sync path and never streamed at all.
    # Force the load so these tests exercise the streaming path deterministically.
    Code.ensure_loaded!(OptimalSystemAgent.Providers.Anthropic)

    # NOT the test process's mailbox. `Anthropic.collect_stream/3` drives its
    # `into: :self` loop with a bare `receive do message -> ...` and DISCARDS
    # anything `Req.parse_message/2` does not recognise — so probe messages
    # sent to the test process while a stream is in flight are silently eaten.
    # An Agent is out of band and cannot be swallowed.
    {:ok, collector} = Agent.start_link(fn -> [] end)
    test_pid = collector

    # A fresh port window per test. Sharing one window let a previous test's
    # stub (still shutting down) own the port a later test then bound around,
    # which made the fixture flaky instead of the code under test.
    window = @port_base + rem(System.unique_integer([:positive]), 200) * 4

    # Primary: streams ONE text delta, then fails mid-stream.
    {primary_srv, primary_port} = start_stub(window, test_pid, 0, :die_mid_stream)
    # Fallback: healthy. Any request reaching it is the bug.
    {fallback_srv, fallback_port} = start_stub(window + 2, test_pid, 0, :healthy)

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

    put(:anthropic_url, "http://127.0.0.1:#{primary_port}/v1")
    put(:anthropic_api_key, "sk-ant-test-not-a-real-key")
    put(:openai_url, "http://127.0.0.1:#{fallback_port}/v1")
    put(:openai_api_key, "sk-test-not-a-real-key")
    # Three entries, healthy stub LAST, on purpose. `stream_fallback_chain/5`
    # drops the failed provider twice: `Enum.drop_while(&(&1 == provider))`
    # removes it, and then the `[_ | rest] -> rest` clause removes one MORE —
    # so the provider immediately after the failed one is always skipped.
    # (That double-drop looks like a real bug, mirrored in `try_fallback_chain/4`,
    # but it is pre-existing and outside this change's scope; encoding it here
    # keeps the fixture honest about what the code actually does.)
    put(:fallback_chain, [:anthropic, :ollama, :openai])
    put(:default_provider, :anthropic)

    on_exit(fn ->
      restore_all(prev)

      if prev_retries,
        do: System.put_env("OSA_API_MAX_RETRIES", prev_retries),
        else: System.delete_env("OSA_API_MAX_RETRIES")

      # :normal is IGNORED by a non-trapping process — the stubs used to
      # outlive their test and squat on the port the next one wanted.
      Process.exit(primary_srv, :kill)
      Process.exit(fallback_srv, :kill)
    end)

    {:ok, collector: collector}
  end

  defp record(collector, event), do: Agent.update(collector, &[event | &1])

  defp events(collector), do: collector |> Agent.get(& &1) |> Enum.reverse()

  defp reset(collector), do: Agent.update(collector, fn _ -> [] end)

  defp hits(collector, kind),
    do: for({:hit, ^kind, path} <- events(collector), do: path)

  defp deltas(collector),
    do: for({:delta, text} <- events(collector), do: text)

  # The production callback (`Agent.Loop.LLMClient`) marks output observed on
  # the first visible delta. Mirroring it here is the whole point: the flag is
  # set by whoever is rendering, and the registry must consult it.
  defp observing_callback(collector) do
    fn
      {:text_delta, text} ->
        Resilience.mark_output_observed()
        record(collector, {:delta, text})
        :ok

      _ ->
        :ok
    end
  end

  defp messages, do: [%{role: "user", content: "hello"}]

  describe "once output has been streamed, fallback is suppressed" do
    test "the fallback provider is never called", %{collector: c} do
      reset(c)

      Registry.chat_stream(messages(), observing_callback(c),
        provider: :anthropic,
        max_tokens: 64
      )

      assert hits(c, :primary) != [],
             "precondition: the primary provider must actually have been called"

      assert deltas(c) != [],
             "precondition: the primary must have put visible output on screen"

      assert hits(c, :fallback) == [],
             "the fallback provider re-streams the response from scratch — reaching it " <>
               "after output was already on screen duplicates what the user saw"
    end

    test "the same-provider sync retry is suppressed too", %{collector: c} do
      reset(c)

      Registry.chat_stream(messages(), observing_callback(c),
        provider: :anthropic,
        max_tokens: 64
      )

      primary_hits = hits(c, :primary)

      assert length(primary_hits) == 1,
             "fallback_sync_stream/4 pushes the WHOLE response through the same live " <>
               "callback — it is a duplicate emitter exactly like a retry is, and must " <>
               "be suppressed by the same door (saw #{length(primary_hits)} calls)"
    end

    test "the user's callback sees the streamed text exactly once", %{collector: c} do
      reset(c)

      Registry.chat_stream(messages(), observing_callback(c),
        provider: :anthropic,
        max_tokens: 64
      )

      seen = deltas(c)

      assert seen != [], "precondition: the primary must have streamed something visible"

      assert length(seen) == 1,
             "the user must not watch the same text render twice (got: #{inspect(seen)})"
    end

    test "the failure is surfaced honestly rather than papered over", %{collector: c} do
      reset(c)

      result =
        Registry.chat_stream(messages(), observing_callback(c),
          provider: :anthropic,
          max_tokens: 64
        )

      assert {:error, _reason} = result,
             "past the one-way door the only honest options are finish or fail — " <>
               "never a silently-duplicated success"
    end
  end

  describe "without observed output the fallback still works" do
    test "a stream that fails BEFORE emitting anything falls back normally",
         %{collector: c} do
      reset(c)

      # The "SILENT" sentinel makes the stub fail WITHOUT emitting a delta, so
      # nothing reached the user: re-sending is free and the chain must still
      # do its job.
      Registry.chat_stream(
        [%{role: "user", content: "SILENT"}],
        observing_callback(c),
        provider: :anthropic,
        max_tokens: 64
      )

      assert deltas(c) == [], "precondition: nothing must have reached the user"

      assert hits(c, :fallback) != [],
             "suppression must be conditional on observed output, not a blanket disable " <>
               "of the fallback chain"
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

  defp start_stub(base, test_pid, attempt, mode) do
    port = base + attempt

    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, probe} ->
        :ok = :gen_tcp.close(probe)

        {:ok, server} =
          Bandit.start_link(
            plug: {__MODULE__.StubPlug, {test_pid, mode}},
            ip: {127, 0, 0, 1},
            port: port,
            startup_log: false
          )

        {server, port}

      {:error, _} ->
        start_stub(base, test_pid, attempt + 1, mode)
    end
  end

  defmodule StubPlug do
    @moduledoc false
    import Plug.Conn

    def init(state), do: state

    # Streams a well-formed opening, optionally one real text delta, then a
    # first-class mid-stream `event: error` (Anthropic's own protocol for
    # "overloaded halfway through"). A transient error, so `should_fallback?/1`
    # says yes — the fallback is declined for the OTHER reason, which is
    # exactly what these tests pin.
    #
    # The "SILENT" sentinel in the prompt suppresses the text delta, giving the
    # control case: a stream that fails with nothing on screen.
    def call(conn, {test_pid, :die_mid_stream}) do
      {:ok, raw, conn} = read_body(conn)
      Agent.update(test_pid, &[{:hit, :primary, conn.request_path} | &1])

      silent? = String.contains?(raw, "SILENT")

      if not String.contains?(raw, "\"stream\":true") do
        # A NON-streaming request (the same-provider sync attempt). Answering
        # it with SSE made the provider's JSON parser raise, and a raise is
        # classified non-transient — which stopped the chain for the wrong
        # reason and hid what these tests are actually about. A clean 503 is a
        # transient failure, so the chain proceeds to the fallback provider.
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          503,
          Jason.encode!(%{
            "type" => "error",
            "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
          })
        )
      else
        stream_response(conn, silent?)
      end
    end

    defp stream_response(conn, silent?) do
      visible =
        if silent? do
          # Fail before any content block opens: nothing ever reaches the user.
          ""
        else
          sse("content_block_start", content_block_start()) <>
            sse("content_block_delta", text_delta())
        end

      # ONE chunk. Framing the events separately let Bandit and the SSE parser
      # race over frame boundaries, which made the fixture flaky rather than
      # the code under test.
      body =
        sse("message_start", message_start()) <>
          visible <>
          sse("error", error_event())

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, body)

      conn
    end

    def call(conn, {test_pid, :healthy}) do
      {:ok, _raw, conn} = read_body(conn)
      Agent.update(test_pid, &[{:hit, :fallback, conn.request_path} | &1])

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, healthy_body())
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
        "delta" => %{"type" => "text_delta", "text" => "partial answer the user can see"}
      }
    end

    defp error_event do
      %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded mid-stream"}
      }
    end

    defp healthy_body do
      Jason.encode!(%{
        "choices" => [
          %{
            "message" => %{"role" => "assistant", "content" => "fallback answer"},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1},
        "content" => [%{"type" => "text", "text" => "fallback answer"}],
        "message" => %{"role" => "assistant", "content" => "fallback answer"}
      })
    end
  end
end
