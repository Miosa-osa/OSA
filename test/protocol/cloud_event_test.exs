defmodule OptimalSystemAgent.Protocol.CloudEventTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Protocol.CloudEvent

  # ---------------------------------------------------------------------------
  # new/1 — creation
  # ---------------------------------------------------------------------------

  describe "new/1" do
    test "creates event with auto-generated id and time" do
      event = CloudEvent.new(%{type: "com.osa.test", source: "urn:osa:agent:abc"})

      assert %CloudEvent{} = event
      assert event.type == "com.osa.test"
      assert event.source == "urn:osa:agent:abc"
      assert event.specversion == "1.0"
      assert event.datacontenttype == "application/json"
      assert String.starts_with?(event.id, "evt_")
      assert byte_size(event.id) > 4
      assert is_binary(event.time)
    end

    test "uses provided id and time when given" do
      event =
        CloudEvent.new(%{
          type: "com.osa.test",
          source: "urn:osa:test",
          id: "custom-id-123",
          time: "2026-01-01T00:00:00Z"
        })

      assert event.id == "custom-id-123"
      assert event.time == "2026-01-01T00:00:00Z"
    end

    test "raises when type is missing" do
      assert_raise KeyError, fn ->
        CloudEvent.new(%{source: "urn:osa:test"})
      end
    end

    test "raises when source is missing" do
      assert_raise KeyError, fn ->
        CloudEvent.new(%{type: "com.osa.test"})
      end
    end

    test "sets subject when provided" do
      event =
        CloudEvent.new(%{
          type: "com.osa.test",
          source: "urn:osa:test",
          subject: "agent-42"
        })

      assert event.subject == "agent-42"
    end

    test "sets data when provided" do
      event =
        CloudEvent.new(%{
          type: "com.osa.test",
          source: "urn:osa:test",
          data: %{key: "value"}
        })

      assert event.data == %{key: "value"}
    end
  end

  # ---------------------------------------------------------------------------
  # encode/1 — JSON encoding
  # ---------------------------------------------------------------------------

  describe "encode/1" do
    test "produces valid JSON" do
      event =
        CloudEvent.new(%{
          type: "com.osa.heartbeat",
          source: "urn:osa:agent:s1",
          data: %{cpu: 42.5}
        })

      assert {:ok, json} = CloudEvent.encode(event)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["type"] == "com.osa.heartbeat"
      assert decoded["source"] == "urn:osa:agent:s1"
      assert decoded["specversion"] == "1.0"
      assert decoded["data"]["cpu"] == 42.5
    end

    test "includes subject in JSON when present" do
      event =
        CloudEvent.new(%{
          type: "com.osa.test",
          source: "urn:osa:test",
          subject: "my-subject"
        })

      assert {:ok, json} = CloudEvent.encode(event)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["subject"] == "my-subject"
    end

    test "omits subject from JSON when nil" do
      event =
        CloudEvent.new(%{
          type: "com.osa.test",
          source: "urn:osa:test"
        })

      assert {:ok, json} = CloudEvent.encode(event)
      assert {:ok, decoded} = Jason.decode(json)
      refute Map.has_key?(decoded, "subject")
    end

    test "returns error when type is nil" do
      event = %CloudEvent{type: nil, source: "urn:osa:test"}
      assert {:error, "type is required"} = CloudEvent.encode(event)
    end

    test "returns error when source is nil" do
      event = %CloudEvent{type: "com.osa.test", source: nil}
      assert {:error, "source is required"} = CloudEvent.encode(event)
    end
  end

  # ---------------------------------------------------------------------------
  # decode/1 — JSON decoding
  # ---------------------------------------------------------------------------

  describe "decode/1" do
    test "parses JSON to CloudEvent struct" do
      json =
        Jason.encode!(%{
          "specversion" => "1.0",
          "type" => "com.osa.task_complete",
          "source" => "urn:osa:agent:x1",
          "id" => "evt_abc123",
          "time" => "2026-02-27T12:00:00Z",
          "datacontenttype" => "application/json",
          "data" => %{"status" => "done"}
        })

      assert {:ok, event} = CloudEvent.decode(json)
      assert %CloudEvent{} = event
      assert event.type == "com.osa.task_complete"
      assert event.source == "urn:osa:agent:x1"
      assert event.id == "evt_abc123"
      assert event.data == %{"status" => "done"}
    end

    test "rejects missing type" do
      json =
        Jason.encode!(%{
          "specversion" => "1.0",
          "source" => "urn:osa:test"
        })

      assert {:error, "type is required"} = CloudEvent.decode(json)
    end

    test "rejects missing source" do
      json =
        Jason.encode!(%{
          "specversion" => "1.0",
          "type" => "com.osa.test"
        })

      assert {:error, "source is required"} = CloudEvent.decode(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = CloudEvent.decode("not valid json {{{")
    end

    test "auto-generates id when missing from JSON" do
      json =
        Jason.encode!(%{
          "type" => "com.osa.test",
          "source" => "urn:osa:test"
        })

      assert {:ok, event} = CloudEvent.decode(json)
      assert String.starts_with?(event.id, "evt_")
    end

    test "defaults specversion to 1.0 when missing" do
      json =
        Jason.encode!(%{
          "type" => "com.osa.test",
          "source" => "urn:osa:test"
        })

      assert {:ok, event} = CloudEvent.decode(json)
      assert event.specversion == "1.0"
    end
  end

  # ---------------------------------------------------------------------------
  # from_bus_event/1 — internal event conversion
  # ---------------------------------------------------------------------------

  describe "from_bus_event/1" do
    test "converts internal event to CloudEvent" do
      bus_event = %{
        event: :agent_started,
        session_id: "sess_abc",
        agent_id: "agent_42",
        cpu_load: 12.5
      }

      event = CloudEvent.from_bus_event(bus_event)

      assert %CloudEvent{} = event
      assert event.type == "com.osa.agent_started"
      assert event.source == "urn:osa:agent:sess_abc"
      assert event.data.agent_id == "agent_42"
      assert event.data.cpu_load == 12.5
      refute Map.has_key?(event.data, :event)
      refute Map.has_key?(event.data, :session_id)
    end

    test "uses 'unknown' session_id when not provided" do
      bus_event = %{event: :heartbeat, cpu: 50.0}
      event = CloudEvent.from_bus_event(bus_event)

      assert event.source == "urn:osa:agent:unknown"
    end

    test "preserves subject from bus event" do
      bus_event = %{event: :task_done, session_id: "s1", subject: "deploy-v2"}
      event = CloudEvent.from_bus_event(bus_event)

      assert event.subject == "deploy-v2"
    end
  end

  # ---------------------------------------------------------------------------
  # to_bus_event/1 — CloudEvent to internal format
  # ---------------------------------------------------------------------------

  describe "to_bus_event/1" do
    test "converts CloudEvent back to internal format" do
      cloud_event =
        CloudEvent.new(%{
          type: "com.osa.deploy_complete",
          source: "urn:osa:agent:s1",
          data: %{version: "2.0", duration_ms: 1500}
        })

      bus_event = CloudEvent.to_bus_event(cloud_event)

      assert bus_event.event == :deploy_complete
      assert bus_event.source == "urn:osa:agent:s1"
      assert bus_event.version == "2.0"
      assert bus_event.duration_ms == 1500
    end

    test "handles type without com.osa prefix" do
      cloud_event =
        CloudEvent.new(%{
          type: "custom.event",
          source: "urn:osa:test"
        })

      bus_event = CloudEvent.to_bus_event(cloud_event)
      assert bus_event.event == :"custom.event"
    end
  end

  # ---------------------------------------------------------------------------
  # Round-trip — encode then decode
  # ---------------------------------------------------------------------------

  describe "round-trip" do
    test "encode then decode preserves data" do
      original =
        CloudEvent.new(%{
          type: "com.osa.round_trip",
          source: "urn:osa:agent:rt1",
          subject: "test-subject",
          data: %{key: "value", count: 42, nested: %{a: 1}}
        })

      assert {:ok, json} = CloudEvent.encode(original)
      assert {:ok, decoded} = CloudEvent.decode(json)

      assert decoded.type == original.type
      assert decoded.source == original.source
      assert decoded.subject == original.subject
      assert decoded.id == original.id
      assert decoded.time == original.time
      assert decoded.specversion == original.specversion
      # JSON decode converts atom keys to strings
      assert decoded.data["key"] == "value"
      assert decoded.data["count"] == 42
      assert decoded.data["nested"]["a"] == 1
    end
  end
end
