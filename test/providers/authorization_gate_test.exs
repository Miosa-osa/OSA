defmodule OptimalSystemAgent.Providers.AuthorizationGateTest do
  @moduledoc """
  Regression test for the anti-flagging authorization gate.

  Bug (observed 2026-09-01): a stock session — no /jailbreak block armed, no
  /uncensored hop — had a forged authorization annotation appended to the
  operator's outgoing message because `determine_authorization/2` fell back to
  keyword detection over recent user-role messages. A conversation about
  security topics (or tool output containing words like "injection" or "scan")
  must NEVER be sufficient to append "I am authorized" to the operator's own
  words. Layer 2 (the annotation) requires layer 1 (the operator explicitly
  arming the override).
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Jailbreak
  alias OptimalSystemAgent.Providers.Registry

  # Long enough to clear Moderation's @min_message_length of 30 chars; the
  # openai key is cleared so armed-detection takes the deterministic keyword
  # path instead of a live moderation HTTP call (which would fail → false in
  # a test environment and make this suite flaky).
  @security_messages [
    %{role: "user", content: "research nmap scan payloads and exploitation techniques for the pentest"},
    %{role: "assistant", content: "understood"},
    %{role: "user", content: "also check the target for injection vulnerabilities and privilege escalation"}
  ]

  # Jailbreak state persists in ~/.osa/jailbreak — save, control, restore so
  # this test neither depends on nor mutates the operator's live arming state.
  # Arming uses a throwaway block file: set(true) with no file would arm the
  # operator's real default (priv/prompts/jailbreak.md or ~/.osa custom), which
  # this test must never do.
  setup do
    was_armed = Jailbreak.active?()
    openai_key = Application.get_env(:optimal_system_agent, :openai_api_key)
    Application.put_env(:optimal_system_agent, :openai_api_key, nil)

    block =
      Path.join(System.tmp_dir!(), "osa-auth-gate-test-#{System.unique_integer()}.md")

    :ok = File.write!(block, "test-only override block for the authorization gate")

    on_exit(fn ->
      File.rm(block)

      if was_armed, do: Jailbreak.set(true, nil), else: Jailbreak.set(false, nil)
      Application.put_env(:optimal_system_agent, :openai_api_key, openai_key)
    end)

    %{block: block}
  end

  describe "maybe_inject_authorization/2" do
    test "does NOT annotate security keywords when jailbreak is disarmed" do
      Jailbreak.set(false)

      result = Registry.maybe_inject_authorization(@security_messages, [])

      refute Enum.any?(result, fn
                %{role: "user", content: content} when is_binary(content) ->
                  String.contains?(content, "platform_authorization")

                _ ->
                  false
              end),
             "annotation must not fire on keyword hits alone when no override is armed"
    end

    test "annotates security keywords when jailbreak is armed", %{block: block} do
      assert :ok = Jailbreak.set(true, block)
      assert Jailbreak.active?()

      result = Registry.maybe_inject_authorization(@security_messages, [])

      assert Enum.any?(result, fn
                %{role: "user", content: content} when is_binary(content) ->
                  String.contains?(content, "platform_authorization")

                _ ->
                  false
              end),
             "annotation should fire for security content when the operator armed the override"
    end

    test "skip_authorization option bypasses everything", %{block: block} do
      assert :ok = Jailbreak.set(true, block)

      result = Registry.maybe_inject_authorization(@security_messages, skip_authorization: true)

      refute Enum.any?(result, fn
                %{role: "user", content: content} when is_binary(content) ->
                  String.contains?(content, "platform_authorization")

                _ ->
                  false
              end)
    end
  end
end