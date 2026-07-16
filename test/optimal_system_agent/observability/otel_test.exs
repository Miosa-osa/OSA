defmodule OptimalSystemAgent.Observability.OTelTest do
  # async: false — the toggle tests mutate global application env.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Observability.OTel

  defmodule RecordingAdapter do
    @moduledoc "Test adapter that records GenAI calls into the caller's process dict."
    @behaviour OptimalSystemAgent.Observability.OTel

    @impl true
    def on_gen_ai(operation, attributes) do
      Process.put(:otel_calls, [{operation, attributes} | Process.get(:otel_calls, [])])
      :ok
    end
  end

  defmodule BoomAdapter do
    @behaviour OptimalSystemAgent.Observability.OTel
    @impl true
    def on_gen_ai(_operation, _attributes), do: raise("boom")
  end

  describe "gen_ai_attributes/1" do
    test "builds OpenTelemetry GenAI semantic-convention keys, omitting nils" do
      attrs =
        OTel.gen_ai_attributes(
          operation: "chat",
          model: "claude-sonnet-4-6",
          conversation_id: "sess-1",
          tool_name: nil
        )

      assert attrs["gen_ai.operation.name"] == "chat"
      assert attrs["gen_ai.request.model"] == "claude-sonnet-4-6"
      assert attrs["gen_ai.conversation.id"] == "sess-1"
      refute Map.has_key?(attrs, "gen_ai.tool.name")
    end

    test "expands a usage map into gen_ai.usage.* integer attributes" do
      attrs =
        OTel.gen_ai_attributes(
          operation: "chat",
          usage: %{input_tokens: 1234, output_tokens: 56}
        )

      assert attrs["gen_ai.usage.input_tokens"] == 1234
      assert attrs["gen_ai.usage.output_tokens"] == 56
    end

    test "tolerates string-keyed usage and stringifies atom values" do
      attrs =
        OTel.gen_ai_attributes(
          operation: :execute_tool,
          tool_name: :file_read,
          usage: %{"input_tokens" => 10}
        )

      assert attrs["gen_ai.operation.name"] == "execute_tool"
      assert attrs["gen_ai.tool.name"] == "file_read"
      assert attrs["gen_ai.usage.input_tokens"] == 10
    end
  end

  describe "emit/2 toggle" do
    setup do
      prev_enabled = Application.get_env(:optimal_system_agent, :otel_enabled)
      prev_adapter = Application.get_env(:optimal_system_agent, :otel_adapter)

      on_exit(fn ->
        restore(:otel_enabled, prev_enabled)
        restore(:otel_adapter, prev_adapter)
      end)

      Process.delete(:otel_calls)
      :ok
    end

    test "is a no-op (adapter not called) when disabled" do
      Application.put_env(:optimal_system_agent, :otel_enabled, false)
      Application.put_env(:optimal_system_agent, :otel_adapter, RecordingAdapter)

      assert OTel.emit(:chat, %{"gen_ai.operation.name" => "chat"}) == :ok
      assert Process.get(:otel_calls) == nil
    end

    test "forwards to the configured adapter when enabled" do
      Application.put_env(:optimal_system_agent, :otel_enabled, true)
      Application.put_env(:optimal_system_agent, :otel_adapter, RecordingAdapter)

      attrs = %{"gen_ai.operation.name" => "chat", "gen_ai.request.model" => "m"}
      assert OTel.emit(:chat, attrs) == :ok

      assert [{:chat, ^attrs}] = Process.get(:otel_calls)
    end

    test "never raises even if the adapter crashes" do
      Application.put_env(:optimal_system_agent, :otel_enabled, true)
      Application.put_env(:optimal_system_agent, :otel_adapter, BoomAdapter)

      assert OTel.emit(:chat, %{}) == :ok
    end

    test "default adapter is the Noop adapter" do
      Application.delete_env(:optimal_system_agent, :otel_adapter)
      assert OTel.adapter() == OptimalSystemAgent.Observability.OTel.Noop
    end
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, val), do: Application.put_env(:optimal_system_agent, key, val)
end
