defmodule OptimalSystemAgent.Agent.DelegationPolicyTest do
  @moduledoc """
  Tri-mode delegation policy (primitive #34, Codex parity):

    * the `DelegationPolicy` resolver / intent detector,
    * `Loop.ToolFilter` stripping `delegate` per policy, and
    * `Delegate.Handler.check_permissions/2` denying disallowed delegation.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.DelegationPolicy
  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Tools.Builtins.Delegate.Handler
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    prev = Application.get_env(:optimal_system_agent, :effort_level)
    prev_policy = Application.get_env(:optimal_system_agent, :delegation_policy)
    # Medium effort disables FastPath tool trimming so filter output is stable.
    Effort.set(:medium)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:optimal_system_agent, :effort_level, prev),
        else: Application.delete_env(:optimal_system_agent, :effort_level)

      if prev_policy,
        do: Application.put_env(:optimal_system_agent, :delegation_policy, prev_policy),
        else: Application.delete_env(:optimal_system_agent, :delegation_policy)
    end)

    :ok
  end

  describe "normalize/1" do
    test "passes through valid atoms" do
      assert DelegationPolicy.normalize(:disabled) == :disabled
      assert DelegationPolicy.normalize(:explicit_only) == :explicit_only
      assert DelegationPolicy.normalize(:proactive) == :proactive
    end

    test "accepts string forms including hyphenated" do
      assert DelegationPolicy.normalize("disabled") == :disabled
      assert DelegationPolicy.normalize("explicit-only") == :explicit_only
      assert DelegationPolicy.normalize("explicit_only") == :explicit_only
      assert DelegationPolicy.normalize("proactive") == :proactive
    end

    test "unknown / nil fall back to the default mode" do
      assert DelegationPolicy.normalize("nonsense") == DelegationPolicy.default_mode()
      assert DelegationPolicy.normalize(nil) == DelegationPolicy.default_mode()
      assert DelegationPolicy.normalize(42) == DelegationPolicy.default_mode()
    end
  end

  describe "resolve/1" do
    test "reads the state field over the config default" do
      assert DelegationPolicy.resolve(%{delegation_policy: :disabled}) == :disabled
      assert DelegationPolicy.resolve(%{delegation_policy: "explicit-only"}) == :explicit_only
    end

    test "falls back to the configured default when unset" do
      Application.delete_env(:optimal_system_agent, :delegation_policy)
      assert DelegationPolicy.resolve(%{}) == :proactive

      Application.put_env(:optimal_system_agent, :delegation_policy, :disabled)
      assert DelegationPolicy.resolve(%{}) == :disabled
    end
  end

  describe "user_requested?/1" do
    test "true when the latest user message asks to delegate" do
      assert DelegationPolicy.user_requested?([
               %{role: "user", content: "please delegate this to a subagent"}
             ])

      assert DelegationPolicy.user_requested?([
               %{role: "user", content: "run these in parallel"}
             ])

      assert DelegationPolicy.user_requested?([
               %{"role" => "user", "content" => "fan out the work"}
             ])
    end

    test "false for ordinary work requests" do
      refute DelegationPolicy.user_requested?([
               %{role: "user", content: "fix the failing test"}
             ])

      refute DelegationPolicy.user_requested?([])
      refute DelegationPolicy.user_requested?(nil)
    end

    test "only inspects the most recent user message" do
      messages = [
        %{role: "user", content: "delegate this"},
        %{role: "assistant", content: "ok"},
        %{role: "user", content: "actually just read the file"}
      ]

      refute DelegationPolicy.user_requested?(messages)
    end
  end

  describe "allow?/2" do
    test "proactive always allows; disabled never" do
      assert DelegationPolicy.allow?(:proactive, [])
      refute DelegationPolicy.allow?(:disabled, [])
    end

    test "explicit_only gates on user intent" do
      refute DelegationPolicy.allow?(:explicit_only, [%{role: "user", content: "do X"}])
      assert DelegationPolicy.allow?(:explicit_only, [%{role: "user", content: "delegate X"}])
    end
  end

  # ── ToolFilter integration ──────────────────────────────────────────────

  defp delegate_tools do
    ~w(file_read shell_execute delegate create_agent) |> Enum.map(&%{name: &1})
  end

  describe "ToolFilter delegation policy gating" do
    test "proactive keeps spawning tools" do
      names =
        ToolFilter.filter(delegate_tools(), %{
          provider: :anthropic,
          messages: [],
          delegation_policy: :proactive
        })
        |> Enum.map(& &1.name)

      assert "delegate" in names
      assert "create_agent" in names
    end

    test "disabled strips spawning tools but keeps others" do
      names =
        ToolFilter.filter(delegate_tools(), %{
          provider: :anthropic,
          messages: [],
          delegation_policy: :disabled
        })
        |> Enum.map(& &1.name)

      refute "delegate" in names
      refute "create_agent" in names
      assert "file_read" in names
      assert "shell_execute" in names
    end

    test "explicit_only strips unless the user asked" do
      no_ask =
        ToolFilter.filter(delegate_tools(), %{
          provider: :anthropic,
          messages: [%{role: "user", content: "fix the build"}],
          delegation_policy: :explicit_only
        })
        |> Enum.map(& &1.name)

      refute "delegate" in no_ask

      asked =
        ToolFilter.filter(delegate_tools(), %{
          provider: :anthropic,
          messages: [%{role: "user", content: "delegate this to a subagent"}],
          delegation_policy: :explicit_only
        })
        |> Enum.map(& &1.name)

      assert "delegate" in asked
    end
  end

  # ── Handler enforcement (defense-in-depth) ───────────────────────────────

  defp ctx(policy, messages) do
    %{UseContext.empty() | delegation_policy: policy, messages: messages}
  end

  describe "Handler.check_permissions/2 policy enforcement" do
    test "proactive allows" do
      assert {:allow, _} = Handler.check_permissions(%{"task" => "x"}, ctx(:proactive, []))
    end

    test "disabled denies" do
      assert {:deny, msg} = Handler.check_permissions(%{"task" => "x"}, ctx(:disabled, []))
      assert msg =~ "disabled"
    end

    test "explicit_only denies without user intent, allows with it" do
      assert {:deny, _} =
               Handler.check_permissions(
                 %{"task" => "x"},
                 ctx(:explicit_only, [%{role: "user", content: "do X"}])
               )

      assert {:allow, _} =
               Handler.check_permissions(
                 %{"task" => "x"},
                 ctx(:explicit_only, [%{role: "user", content: "delegate X to a subagent"}])
               )
    end

    test "blank task is still denied regardless of policy" do
      assert {:deny, msg} = Handler.check_permissions(%{"task" => "  "}, ctx(:proactive, []))
      assert msg =~ "blank"
    end
  end
end
