defmodule OptimalSystemAgent.Providers.ModelFallbackTest do
  @moduledoc """
  Explicit per-model fallback (item 19) — "when the chosen model refuses,
  errors persistently or is unavailable, retry on a configured fallback
  model", layered onto the EXISTING provider-level `FallbackChain` rather than
  duplicated (see `fallback_chain.ex`'s `@model_fallback_key` note).

  Uses the `:mock` provider (registered only in `Mix.env() == :test`) so the
  whole chain runs with no real provider HTTP.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Providers.FallbackChain, as: FC
  alias OptimalSystemAgent.Test.MockProvider

  setup do
    prev_model_fallback = Application.fetch_env(:optimal_system_agent, :model_fallback)
    prev_chain = Application.fetch_env(:optimal_system_agent, :fallback_chain)

    # Pin the provider chain to just `:mock` — this suite is about the MODEL
    # hop inside one provider, not the cross-provider chain (already covered
    # by `fallback_chain_test.exs`).
    Application.put_env(:optimal_system_agent, :fallback_chain, [:mock])

    MockProvider.reset()
    MockProvider.reset_last_opts()
    MockProvider.reset_round_trips()
    Application.delete_env(:optimal_system_agent, :mock_provider_error)
    Application.delete_env(:optimal_system_agent, :mock_provider_final_text)

    on_exit(fn ->
      case prev_model_fallback do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :model_fallback, v)
        :error -> Application.delete_env(:optimal_system_agent, :model_fallback)
      end

      case prev_chain do
        {:ok, v} -> Application.put_env(:optimal_system_agent, :fallback_chain, v)
        :error -> Application.delete_env(:optimal_system_agent, :fallback_chain)
      end

      Application.delete_env(:optimal_system_agent, :mock_provider_error)
      Application.delete_env(:optimal_system_agent, :mock_provider_final_text)
    end)

    :ok
  end

  describe "model_fallbacks/1 — configuration parsing" do
    test "no entry configured → empty list" do
      Application.delete_env(:optimal_system_agent, :model_fallback)
      assert FC.model_fallbacks("claude-opus-5") == []
    end

    test "a bare model string normalizes to {nil, model} (same provider)" do
      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "glm-5.2:cloud" => ["glm-5.3:cloud"]
      })

      assert FC.model_fallbacks("glm-5.2:cloud") == [{nil, "glm-5.3:cloud"}]
    end

    test "an explicit {provider, model} pin is preserved" do
      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "claude-opus-5" => [{:anthropic, "claude-sonnet-5"}]
      })

      assert FC.model_fallbacks("claude-opus-5") == [{:anthropic, "claude-sonnet-5"}]
    end

    test "mixed chain, in order" do
      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "gpt-6-astra" => ["gpt-6-sol", {:anthropic, "claude-sonnet-5"}]
      })

      assert FC.model_fallbacks("gpt-6-astra") == [
               {nil, "gpt-6-sol"},
               {:anthropic, "claude-sonnet-5"}
             ]
    end

    test "a single (non-list) entry is wrapped" do
      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "claude-opus-5" => "claude-sonnet-5"
      })

      assert FC.model_fallbacks("claude-opus-5") == [{nil, "claude-sonnet-5"}]
    end
  end

  describe "chat_with_fallback/2 — same-provider model fallback fires on error" do
    test "falls back to the configured model and reports which one answered" do
      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "model-a" => ["model-b"]
      })

      # Fail exactly once (the first hop, requesting "model-a"), then answer.
      # Key the fault on the REQUESTED MODEL (via `last_opts/0`, recorded
      # before `forced_error/1` runs), not on a call counter — Registry's own
      # same-provider resilience layer (`stream_with_fallback/5`'s "same-
      # provider sync fallback" step, in particular) can retry the SAME model
      # more than once before FallbackChain's model-hop layer ever sees an
      # error, so a counter that just fails "the first call ever" can be
      # consumed by that internal retry instead of by the hop this test means
      # to fail. Failing every "model-a" attempt (and only those) is robust
      # to however many times Registry retries it internally.
      Application.put_env(:optimal_system_agent, :mock_provider_error, fn _messages ->
        if MockProvider.last_opts()[:model] == "model-a" do
          "boom"
        else
          nil
        end
      end)

      assert {:ok, result, :mock} =
               FC.chat_with_fallback([%{role: "user", content: "hi"}],
                 provider: :mock,
                 model: "model-a"
               )

      assert result.model_used == "model-b"
      assert MockProvider.last_opts()[:model] == "model-b"
    end

    test "an UNCONFIGURED model never model-fallback-hops — normal single attempt" do
      Application.delete_env(:optimal_system_agent, :model_fallback)
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "answer")

      assert {:ok, result, :mock} =
               FC.chat_with_fallback([%{role: "user", content: "hi"}],
                 provider: :mock,
                 model: "model-a"
               )

      assert result.model_used == "model-a"
    end

    test "exhausting the configured model chain still fails (no cross-provider hop pretends to succeed)" do
      Application.put_env(:optimal_system_agent, :fallback_chain, [:mock])

      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "model-a" => ["model-b"]
      })

      Application.put_env(:optimal_system_agent, :mock_provider_error, "always boom")

      assert {:error, _reason} =
               FC.chat_with_fallback([%{role: "user", content: "hi"}],
                 provider: :mock,
                 model: "model-a"
               )
    end

    test "announces the fallback on the event bus, exactly once, with both models named" do
      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "model-a" => ["model-b"]
      })

      # Key the fault on the REQUESTED MODEL (via `last_opts/0`, recorded
      # before `forced_error/1` runs), not on a call counter — Registry's own
      # same-provider resilience layer (`stream_with_fallback/5`'s "same-
      # provider sync fallback" step, in particular) can retry the SAME model
      # more than once before FallbackChain's model-hop layer ever sees an
      # error, so a counter that just fails "the first call ever" can be
      # consumed by that internal retry instead of by the hop this test means
      # to fail. Failing every "model-a" attempt (and only those) is robust
      # to however many times Registry retries it internally.
      Application.put_env(:optimal_system_agent, :mock_provider_error, fn _messages ->
        if MockProvider.last_opts()[:model] == "model-a" do
          "boom"
        else
          nil
        end
      end)

      test_pid = self()
      # A distinct session id per test, and the handler filters on it — Bus
      # dispatches asynchronously (`Task.Supervisor.start_child`, per
      # `fallback_cost_gate_test.exs`'s own note on the same hazard), so a
      # PRECEDING test's own `:model_fallback_used` emission can still be in
      # flight when this test's handler registers. Filtering by session id
      # (rather than sequence-number bounding) is sufficient here because
      # every call in this suite that can emit the event sets a session id of
      # its own.
      session_id = "model-fallback-announce-session-#{System.unique_integer([:positive])}"

      ref =
        OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn payload ->
          if payload.data[:event] == :model_fallback_used and
               payload.data[:session_id] == session_id do
            send(test_pid, {:bus, payload})
          end
        end)

      on_exit(fn -> OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref) end)

      assert {:ok, _result, :mock} =
               FC.chat_with_fallback([%{role: "user", content: "hi"}],
                 provider: :mock,
                 model: "model-a",
                 session_id: session_id
               )

      assert_receive {:bus, %{data: data}}, 2_000
      assert data.requested_model == "model-a"
      assert data.model == "model-b"
      assert data.session_id == session_id

      refute_receive {:bus, _}, 200
    end

    test "no announcement when the requested model itself answers" do
      Application.delete_env(:optimal_system_agent, :model_fallback)
      Application.put_env(:optimal_system_agent, :mock_provider_final_text, "answer")

      test_pid = self()
      session_id = "model-fallback-no-announce-session-#{System.unique_integer([:positive])}"

      ref =
        OptimalSystemAgent.Events.Bus.register_handler(:system_event, fn payload ->
          if payload.data[:event] == :model_fallback_used and
               payload.data[:session_id] == session_id do
            send(test_pid, {:bus, payload})
          end
        end)

      on_exit(fn -> OptimalSystemAgent.Events.Bus.unregister_handler(:system_event, ref) end)

      assert {:ok, _result, :mock} =
               FC.chat_with_fallback([%{role: "user", content: "hi"}],
                 provider: :mock,
                 model: "model-a",
                 session_id: session_id
               )

      refute_receive {:bus, _}, 300
    end
  end

  describe "chat_stream_with_fallback/3 — same-provider model fallback fires on error" do
    test "the {:done, result} callback payload is tagged with the answering model" do
      Application.put_env(:optimal_system_agent, :model_fallback, %{
        "model-a" => ["model-b"]
      })

      # Key the fault on the REQUESTED MODEL (via `last_opts/0`, recorded
      # before `forced_error/1` runs), not on a call counter — Registry's own
      # same-provider resilience layer (`stream_with_fallback/5`'s "same-
      # provider sync fallback" step, in particular) can retry the SAME model
      # more than once before FallbackChain's model-hop layer ever sees an
      # error, so a counter that just fails "the first call ever" can be
      # consumed by that internal retry instead of by the hop this test means
      # to fail. Failing every "model-a" attempt (and only those) is robust
      # to however many times Registry retries it internally.
      Application.put_env(:optimal_system_agent, :mock_provider_error, fn _messages ->
        if MockProvider.last_opts()[:model] == "model-a" do
          "boom"
        else
          nil
        end
      end)

      test_pid = self()

      callback = fn
        {:done, result} -> send(test_pid, {:done, result})
        _other -> :ok
      end

      assert {:ok, :stream_started, :mock} =
               FC.chat_stream_with_fallback(
                 [%{role: "user", content: "hi"}],
                 callback,
                 provider: :mock,
                 model: "model-a"
               )

      assert_receive {:done, result}, 2_000
      assert result.model_used == "model-b"
    end
  end
end
