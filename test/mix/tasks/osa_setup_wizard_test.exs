defmodule Mix.Tasks.Osa.Setup.WizardTest do
  @moduledoc """
  Regression coverage for the first-run wizard crash/hotfix audit.

  These exercise the pure/side-effect-light functions that were split out of
  the wizard specifically to make this bug class testable without a TTY
  (Prompt.select/confirm/text need raw terminal mode, which ExUnit doesn't
  have). See `lib/mix/tasks/osa.setup.wizard.ex` for the fixes:

    * C1 — selecting MIOSA (coming_soon, no :latency_ms) crashed the wizard
      with a CaseClauseError.
    * M2 — Ollama Cloud always demanded OLLAMA_API_KEY and pinned
      OLLAMA_URL=https://ollama.com, breaking the documented keyless
      "signed-in local Ollama" path.
    * m6 — ollama_cloud's default model had drifted to nemotron-3-super:cloud
      instead of the catalog's glm-5.2:cloud.
    * M5 — ollama_local could resolve to the literal model name "default".
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Osa.Setup.Wizard, as: Wizard

  describe "run_health_check/4 (C1-a: MIOSA coming_soon must not crash)" do
    test "the exact MIOSA health_check shape the audit used to crash on (no :latency_ms key)" do
      # This is the literal result Onboarding.health_check(%{"provider" =>
      # "miosa"}) returns (onboarding.ex ~L564-575) — no :latency_ms, so the
      # OLD `case` (which only matched {:ok, %{latency_ms: latency}} and
      # {:error, %{message: msg}}) raised CaseClauseError right here.
      result =
        capture_output(fn ->
          Wizard.run_health_check("miosa", nil, nil, nil)
        end)

      assert {:ok, nil} = result
    end

    test "returns the api_key unchanged (nil here) alongside :ok — never raises" do
      # MIOSA's health_check is a static, network-free {:ok, %{status:
      # "coming_soon", ...}} (onboarding.ex ~L564-575), so calling this twice
      # in a row is still fast/deterministic and re-confirms no raise.
      assert {:ok, nil} =
               capture_output(fn -> Wizard.run_health_check("miosa", nil, "any-model", nil) end)
    end

    defp capture_output(fun) do
      ExUnit.CaptureIO.capture_io(fn ->
        send(self(), {:result, fun.()})
      end)

      receive do
        {:result, result} -> result
      after
        0 -> flunk("expected a result")
      end
    end
  end

  describe "provider_default_model/1 (m6 + M5)" do
    test "ollama_cloud default model is glm-5.2:cloud, matching the catalog" do
      assert Wizard.provider_default_model("ollama_cloud") == "glm-5.2:cloud"
    end

    test "ollama_local has NO hardcoded default — never the literal string 'default'" do
      refute Wizard.provider_default_model("ollama_local") == "default"
      assert Wizard.provider_default_model("ollama_local") == nil
    end

    test "an unrecognized provider also never leaks the literal string 'default'" do
      refute Wizard.provider_default_model("something_unknown") == "default"
      assert Wizard.provider_default_model("something_unknown") == nil
    end

    test "known cloud providers keep their curated defaults" do
      assert Wizard.provider_default_model("miosa") == "nemotron-3-miosa"
      assert Wizard.provider_default_model("anthropic") =~ "claude"
      assert Wizard.provider_default_model("openai") =~ "gpt"
    end
  end

  describe "ollama_cloud_credentials/3 (M2: keyless local vs keyed cloud)" do
    test "local daemon reachable + user chooses the keyless route -> localhost, NO key" do
      assert Wizard.ollama_cloud_credentials(true, true, nil) ==
               {nil, "http://localhost:11434"}
    end

    test "local daemon reachable but user still enters a key -> ollama.com, WITH key" do
      assert Wizard.ollama_cloud_credentials(true, false, "sk-ollama-abc123") ==
               {"sk-ollama-abc123", "https://ollama.com"}
    end

    test "no local daemon -> always ollama.com (with whatever key was collected)" do
      assert Wizard.ollama_cloud_credentials(false, false, "sk-ollama-abc123") ==
               {"sk-ollama-abc123", "https://ollama.com"}
    end

    test "never returns the ollama.com URL when the keyless route was chosen" do
      {_key, url} = Wizard.ollama_cloud_credentials(true, true, nil)
      refute url == "https://ollama.com"
    end
  end

  describe "classify_health_failure/1 (M3: key-rejected vs network)" do
    test "401/403-shaped errors are classified as key_rejected" do
      assert Wizard.classify_health_failure(%{error: "unauthorized"}) == :key_rejected
      assert Wizard.classify_health_failure(%{error: "forbidden"}) == :key_rejected
    end

    test "connection/network errors are NOT classified as key_rejected" do
      assert Wizard.classify_health_failure(%{error: "connection_refused"}) == :network_or_other
      assert Wizard.classify_health_failure(%{error: "timeout"}) == :network_or_other
      assert Wizard.classify_health_failure(%{}) == :network_or_other
    end
  end

  describe "provider_hint/2 (C1-c: coming_soon must be visibly flagged)" do
    test "a coming_soon provider renders its catalog badge, not the plain description" do
      miosa = %{
        id: "miosa",
        description: "Custom + trained models, run your own harness",
        status: "coming_soon",
        badge: "Limited access — request at miosa.ai"
      }

      assert Wizard.provider_hint(miosa, MapSet.new()) ==
               "Limited access — request at miosa.ai"
    end

    test "a coming_soon provider with no badge falls back to a generic label" do
      p = %{id: "x", description: "desc", status: "coming_soon"}
      assert Wizard.provider_hint(p, MapSet.new()) == "coming soon"
    end

    test "detected providers keep priority over the coming_soon badge" do
      p = %{id: "miosa", description: "desc", status: "coming_soon", badge: "badge"}
      assert Wizard.provider_hint(p, MapSet.new(["miosa"])) == "detected ✓"
    end

    test "a normal (non coming_soon) provider still shows its description" do
      p = %{id: "openai", description: "GPT direct"}
      assert Wizard.provider_hint(p, MapSet.new()) == "GPT direct"
    end
  end

  describe "safe_run/1 (C1-b: never show a newcomer a raw stack trace)" do
    test "converts an unexpected raise into a friendly {:error, message} result" do
      result =
        ExUnit.CaptureIO.capture_io(fn ->
          send(
            self(),
            {:safe_run_result, Wizard.safe_run(fn -> raise "boom: unexpected shape" end)}
          )
        end)

      assert result =~ "Something unexpected happened during setup"
      assert result =~ "run 'osa setup' to try again" or result =~ "Run 'osa setup' to try again"

      assert_received {:safe_run_result, {:error, msg}}
      assert msg =~ "boom: unexpected shape"
    end

    test "a normal (non-raising) function's result passes through untouched" do
      assert Wizard.safe_run(fn -> :ok end) == :ok
      assert Wizard.safe_run(fn -> {:ok, "value"} end) == {:ok, "value"}
    end

    test "a CaseClauseError (the exact class of the original MIOSA crash) is caught" do
      raiser = fn ->
        case {:ok, %{status: "coming_soon"}} do
          {:ok, %{latency_ms: latency}} -> latency
        end
      end

      result = ExUnit.CaptureIO.capture_io(fn -> send(self(), Wizard.safe_run(raiser)) end)
      assert result =~ "Something unexpected happened"
      assert_received {:error, _msg}
    end
  end
end
