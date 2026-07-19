defmodule OptimalSystemAgent.Skills.CaptureTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Skills.Capture

  @good %{
    "title" => "Restart the OSA gateway safely",
    "description" => "Kill and restart the gateway without losing active sessions",
    "when_to_use" => "When the gateway is unresponsive or port 18789 is stuck",
    "body" =>
      "1. Check the port with ss -ltnp | rg 18789. 2. Stop via the app. 3. Relaunch and verify sessions reattach."
  }

  describe "accepts high-signal skills" do
    test "a complete, substantive skill validates" do
      assert Capture.validate(@good) == :ok
      assert Capture.high_signal?(@good)
    end

    test "description alone can serve as the trigger" do
      attrs = Map.delete(@good, "when_to_use")
      assert Capture.validate(attrs) == :ok
    end

    test "accepts atom-keyed attrs" do
      attrs = %{
        title: "Restart the gateway safely",
        when_to_use: "When the gateway port is stuck and unresponsive",
        body: "Run ss -ltnp to find the pid, stop via the app, relaunch and verify it binds."
      }

      assert Capture.validate(attrs) == :ok
    end
  end

  describe "rejects low-signal skills" do
    test "rejects a thin one-off body" do
      attrs = %{@good | "body" => "ls"}
      assert {:error, reason} = Capture.validate(attrs)
      assert reason =~ "too thin"
    end

    test "rejects a body with too few words even if long enough in characters" do
      attrs = %{@good | "body" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      assert {:error, reason} = Capture.validate(attrs)
      assert reason =~ "substance"
    end

    test "rejects a missing / trivial trigger" do
      attrs = @good |> Map.delete("when_to_use") |> Map.put("description", "x")
      assert {:error, reason} = Capture.validate(attrs)
      assert reason =~ "when_to_use trigger"
    end

    test "rejects a too-short title" do
      attrs = %{@good | "title" => "ab"}
      assert {:error, reason} = Capture.validate(attrs)
      assert reason =~ "descriptive title"
    end

    test "rejects a body that merely restates the title" do
      restatement = "Restart the gateway service now and then verify it is up"

      attrs = %{
        "title" => restatement,
        "when_to_use" => "When the gateway is stuck and needs a restart",
        "body" => restatement
      }

      assert {:error, reason} = Capture.validate(attrs)
      assert reason =~ "restates the title"
    end

    test "rejects a non-map" do
      assert {:error, _} = Capture.validate("nope")
    end
  end
end
