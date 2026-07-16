defmodule OptimalSystemAgent.Agent.Safety.ModelClassifierTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.Safety.{ModelClassifier, Verdict}

  defp tool(cmd, name \\ "shell_execute") do
    %{name: name, arguments: %{"command" => cmd}}
  end

  # A deterministic "model" that always returns the given risk — injected via
  # ctx[:assessor] so the ambiguous branch never touches the network.
  defp assessor(risk) do
    fn name, _args ->
      %Verdict{risk: risk, category: :model_flagged, matched_rule: "test", tool: name}
    end
  end

  describe "enabled?/0" do
    test "defaults to false (rule-based behavior unchanged)" do
      refute ModelClassifier.enabled?()
    end
  end

  describe "stage 1 — rule fast-paths (no model call)" do
    test "obvious danger returns the rule verdict verbatim, model never consulted" do
      # assessor would say :safe, but rules already flag rm -rf / as dangerous.
      v = ModelClassifier.classify(tool("rm -rf /"), %{assessor: assessor(:safe)})
      assert v.risk == :dangerous
      assert v.category == :mass_delete
    end

    test "obviously benign read-only tool returns safe without consulting the model" do
      # file_read is not a review-worthy tool and rules find nothing → fast safe.
      v =
        ModelClassifier.classify(
          %{name: "file_read", arguments: %{"path" => "/etc/hosts"}},
          %{assessor: assessor(:dangerous)}
        )

      assert v.risk == :safe
      assert v.category == :none
    end
  end

  describe "stage 2 — ambiguous cases combine with the model (higher risk wins)" do
    test "model can escalate a rule-safe command to dangerous" do
      v = ModelClassifier.classify(tool("echo hello"), %{assessor: assessor(:dangerous)})
      assert v.risk == :dangerous
      assert v.category == :model_flagged
    end

    test "model cannot downgrade a rule caution below caution" do
      # curl to a non-allowlisted host is a rule :caution; a :safe model verdict
      # must not lower it (higher-risk wins).
      v =
        ModelClassifier.classify(
          tool("curl https://unknown.example.com/x"),
          %{assessor: assessor(:safe), untrusted_host_allowlist: []}
        )

      assert v.risk == :caution
    end

    test "model escalates a rule caution to dangerous" do
      v =
        ModelClassifier.classify(
          tool("curl https://unknown.example.com/x"),
          %{assessor: assessor(:dangerous), untrusted_host_allowlist: []}
        )

      assert v.risk == :dangerous
      assert v.category == :model_flagged
    end
  end

  describe "stage 3 — heuristic fallback (no model / no assessor)" do
    test "flags a dangerous shape the rule tables leave to the model" do
      # `git reset --hard` is not in the rule tables but the heuristic flags it.
      v = ModelClassifier.classify(tool("git reset --hard HEAD~3"))
      assert v.risk == :dangerous
      assert v.matched_rule == "heuristic:dangerous"
    end

    test "flags shutdown as dangerous via heuristic" do
      v = ModelClassifier.classify(tool("shutdown -h now"))
      assert v.risk == :dangerous
    end

    test "package install is caution (non-blocking) via heuristic" do
      v = ModelClassifier.classify(tool("apt-get install cowsay"))
      assert v.risk in [:caution, :dangerous]
    end

    test "a benign review-worthy command with no risky shape is safe" do
      # Both the rules and the heuristic agree on :safe; on a tie the cleaner
      # rule verdict is kept (higher-risk wins, ties favour the rule path).
      v = ModelClassifier.classify(tool("ls -la"))
      assert v.risk == :safe
    end
  end

  describe "parse_model_response/2" do
    test "parses a JSON risk + reason object" do
      assert {:ok, v} =
               ModelClassifier.parse_model_response(
                 ~s({"risk":"dangerous","reason":"deletes the database"}),
                 "shell_execute"
               )

      assert v.risk == :dangerous
      assert v.category == :model_flagged
      assert v.reason =~ "database"
      assert v.tool == "shell_execute"
    end

    test "tolerates surrounding prose around the JSON" do
      assert {:ok, v} =
               ModelClassifier.parse_model_response(
                 ~s(Here is my assessment: {"risk":"safe","reason":"read-only"} done.)
               )

      assert v.risk == :safe
    end

    test "accepts alternate tier keys and values" do
      assert {:ok, v} = ModelClassifier.parse_model_response(~s({"tier":"high"}))
      assert v.risk == :dangerous
    end

    test "falls back to a keyword scan of free text" do
      assert {:ok, v} =
               ModelClassifier.parse_model_response("This action looks DANGEROUS to me.")

      assert v.risk == :dangerous
    end

    test "returns :error on ununderstandable output" do
      assert :error == ModelClassifier.parse_model_response("¯\\_(ツ)_/¯ hmm")
      assert :error == ModelClassifier.parse_model_response(nil)
    end
  end

  describe "robustness" do
    test "never raises; degrades to the rule verdict on a bad assessor" do
      # assessor that returns a non-Verdict is ignored → heuristic used, no crash.
      v = ModelClassifier.classify(tool("echo hi"), %{assessor: fn _n, _a -> :garbage end})
      assert %Verdict{} = v
      assert v.risk in [:safe, :caution, :dangerous]
    end

    test "handles string-keyed tool_call maps" do
      v = ModelClassifier.classify(%{"name" => "shell_execute", "arguments" => %{"command" => "rm -rf /"}})
      assert v.risk == :dangerous
    end
  end
end
