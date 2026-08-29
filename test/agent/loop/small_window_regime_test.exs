defmodule OptimalSystemAgent.Agent.Loop.SmallWindowRegimeTest do
  @moduledoc """
  The "small model" regime was selected by the PROVIDER ATOM, not by the model.

  Two independent sites made the same mistake:

    * `Agent.Context.build/1` set `lite? = provider in [:ollama, :lmstudio,
      :llamacpp] or max_tok < 40_000`, and
    * `Agent.Loop.ToolFilter.apply_local_provider_budget/2` cut the tool list to
      ten whenever `state.provider` was one of those three atoms.

  Ollama serves CLOUD tags — frontier models proxied to hosted hardware, with
  their full trained window. `Registry.effective_context_window/2` already knows
  this and declines to apply the local `num_ctx` ceiling to them. Both sites
  ignored it and read the transport instead.

  The consequences, MEASURED on the live registry (see the assertions below):

    * the `:lite` static base is 22,971 tokens; `:native_tools` — the variant a
      1M-window model reached over a native-tool transport should get — is
      14,527. The small-window path made the prompt 8,444 tokens BIGGER, on
      every single request, for the one model that could least afford it.
    * the tool list was cut from 37 to 10. That is a capability loss, and it is
      also a latency loss: a model that cannot see the tool it needs takes more
      round-trips, and round-trips are the wall clock.

  Both now key on `Agent.Context.small_window?/2`, a single source of truth
  built on `Registry.effective_context_window/2`.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Agent.Effort
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Providers.Registry, as: ProviderRegistry
  alias OptimalSystemAgent.Soul

  # A model whose window is genuinely large, served over the :ollama transport.
  @cloud_model "glm-5.2:cloud"
  # A model that really is small: local weights under the num_ctx ceiling.
  @small_model "qwen2.5-coder:7b"

  setup do
    previous = Application.get_env(:optimal_system_agent, :effort_level)
    Effort.set(:medium)

    on_exit(fn ->
      if previous do
        Application.put_env(:optimal_system_agent, :effort_level, previous)
      else
        Application.delete_env(:optimal_system_agent, :effort_level)
      end
    end)

    :ok
  end

  # ── The premise: the transport is not the window ────────────────────────

  describe "the premise" do
    test "an Ollama CLOUD tag keeps its full window; local weights do not" do
      assert ProviderRegistry.effective_context_window(@cloud_model, :ollama) >= 1_000_000,
             "if this fails the premise is gone: the registry no longer believes " <>
               "#{@cloud_model} is a hosted frontier model"

      assert ProviderRegistry.effective_context_window(@small_model, :ollama) < 40_000
    end
  end

  # ── Context.small_window?/2 — the shared predicate ──────────────────────

  describe "Context.small_window?/2" do
    test "FALSE for a 1M-window model even though the provider is :ollama" do
      refute Context.small_window?(@cloud_model, :ollama),
             "the provider atom must not decide this — the resolved window must"
    end

    test "TRUE for genuinely small local weights" do
      assert Context.small_window?(@small_model, :ollama)
    end

    test "TRUE for a small window on a cloud provider too — this is not about locality" do
      assert Context.small_window?("gpt-3.5-turbo-0125", :openai) ==
               ProviderRegistry.effective_context_window("gpt-3.5-turbo-0125", :openai) <
                 Context.small_window_tokens()
    end
  end

  # ── The prompt variant ──────────────────────────────────────────────────

  describe "prompt variant selection" do
    test ":lite is LARGER than :native_tools — the small-window path cost tokens" do
      lite = Soul.static_token_count(:lite)
      native = Soul.static_token_count(:native_tools)

      assert lite > native,
             "the whole point of this fix: routing a big model to :lite inflated " <>
               "its prefix. lite=#{lite} native_tools=#{native}"

      IO.puts(
        "\n[measured] static base by variant: " <>
          ":full=#{Soul.static_token_count(:full)} " <>
          ":lite=#{lite} :native_tools=#{native} " <>
          "(:lite - :native_tools = #{lite - native} tokens per request)"
      )
    end

    test "a 1M-window model over :ollama gets :native_tools, not :lite" do
      assert ProviderRegistry.native_tool_schemas?(:ollama),
             "premise: :ollama carries native tool schemas in the request body"

      variant =
        Context.static_base_variant(
          :ollama,
          Context.small_window?(@cloud_model, :ollama)
        )

      assert variant == :native_tools
    end

    # :lite (13.2k) is bigger than :native_tools (8.95k); on a transport that
    # ships tool schemas natively the small window gets the smaller base.
    test "genuinely small weights on a native transport get :native_tools" do
      variant =
        Context.static_base_variant(
          :ollama,
          Context.small_window?(@small_model, :ollama)
        )

      assert variant == :native_tools
      assert Soul.static_token_count(:native_tools) < Soul.static_token_count(:lite)
    end

    test "genuinely small weights on a prompt-text transport keep :lite" do
      assert Context.static_base_variant(:claude_cli, true) == :lite
    end

    test "Context.build/1 assembles the :native_tools prefix for both window sizes on :ollama" do
      big = build_system_content(@cloud_model)
      small = build_system_content(@small_model)

      assert String.starts_with?(big, Soul.static_base(:native_tools)),
             "the assembled system prompt must open with the :native_tools base"

      # The small window used to get :lite here — 4.2k tokens MORE than the
      # native base it now shares with the big window.
      assert String.starts_with?(small, Soul.static_base(:native_tools))
      refute String.starts_with?(small, Soul.static_base(:lite))

      IO.puts(
        "\n[measured] Context.build system prompt bytes: " <>
          "#{@cloud_model}=#{byte_size(big)} #{@small_model}=#{byte_size(small)}"
      )
    end
  end

  # ── The tool budget ─────────────────────────────────────────────────────

  describe "ToolFilter tool budget" do
    defp many_tools(n), do: Enum.map(1..n, &%{name: "tool_#{&1}"})

    test "a 1M-window model over :ollama keeps the whole tool list" do
      tools = many_tools(37)

      filtered =
        ToolFilter.filter(tools, %{
          provider: :ollama,
          model: @cloud_model,
          messages: []
        })

      assert length(filtered) == 37,
             "the tool list was being cut to 10 purely because the transport was " <>
               "ollama; got #{length(filtered)}"
    end

    test "genuinely small weights are still capped at ten" do
      filtered =
        ToolFilter.filter(many_tools(37), %{
          provider: :ollama,
          model: @small_model,
          messages: []
        })

      assert length(filtered) == 10
    end

    # `model: nil` is not "unknown model, be conservative" — it is the normal
    # shape of every non-CLI entry point (`serve`/HTTP included), and the request
    # that follows is sent with the provider's CONFIGURED model. Treating nil as
    # unknown made a nil-model state fall to the local num_ctx ceiling, which
    # cannot match the ":cloud" exemption while the model is nil: on
    # Terminal-Bench that budgeted a live `glm-5.2:cloud` (1M window) as a 32k
    # local model and cut its tool array to ten. `Context.small_window?/2` now
    # resolves nil the same way `build/1` does, so the regime follows the model
    # that will actually serve the request.
    test "no model in state resolves the provider's configured model — cloud tag" do
      with_ollama_model("glm-5.2:cloud", fn ->
        filtered = ToolFilter.filter(many_tools(37), %{provider: :ollama, messages: []})

        assert length(filtered) == 37,
               "the configured model is a hosted 1M tag; nil in the state is not a reason " <>
                 "to pretend otherwise"
      end)
    end

    test "no model in state resolves the provider's configured model — local weights" do
      with_ollama_model(@small_model, fn ->
        filtered = ToolFilter.filter(many_tools(37), %{provider: :ollama, messages: []})

        assert length(filtered) == 10,
               "genuinely small configured weights must still take the cap"
      end)
    end

    defp with_ollama_model(model, fun) do
      previous = Application.get_env(:optimal_system_agent, :ollama_model)
      Application.put_env(:optimal_system_agent, :ollama_model, model)

      try do
        fun.()
      after
        if previous,
          do: Application.put_env(:optimal_system_agent, :ollama_model, previous),
          else: Application.delete_env(:optimal_system_agent, :ollama_model)
      end
    end

    test "the cap prefers file and shell tools when it does apply" do
      tools =
        Enum.map(
          ~w(a b c d e f g h i j k file_read shell_execute ask_user),
          &%{name: &1}
        )

      names =
        ToolFilter.filter(tools, %{
          provider: :ollama,
          model: @small_model,
          messages: [],
          # This test is about the small-window BUDGET's priority ordering, not
          # about the ask_user gate — which is off by default (`AskUserMode`)
          # and would otherwise remove the tool before the budget ever ranks it.
          ask_user_enabled: true
        })
        |> Enum.map(& &1.name)

      assert "file_read" in names
      assert "shell_execute" in names
      assert "ask_user" in names
    end
  end

  # ── Computer-use focus mode had the identical transport bug ─────────────

  describe "computer-use focus mode" do
    test "does NOT collapse the tool list for a big-window model on :ollama" do
      state = %{
        provider: :ollama,
        model: @cloud_model,
        messages: [%{role: "tool", name: "computer_use", content: "ok"}]
      }

      filtered = ToolFilter.filter(many_tools(37), state)
      assert length(filtered) == 37
    end

    test "still collapses for genuinely small local weights" do
      state = %{
        provider: :ollama,
        model: @small_model,
        messages: [%{role: "tool", name: "computer_use", content: "ok"}],
        # As above: the assertion here is the CU focus allowlist, so the
        # independent ask_user gate is opened to keep the two separable.
        ask_user_enabled: true
      }

      tools =
        Enum.map(~w(computer_use file_read ask_user web_search git shell_execute), &%{name: &1})

      names = ToolFilter.filter(tools, state) |> Enum.map(& &1.name)
      assert Enum.sort(names) == ~w(ask_user computer_use file_read)
    end
  end

  defp build_system_content(model) do
    %{messages: [system | _]} =
      Context.build(%{
        session_id: "small-window-test-#{:erlang.unique_integer([:positive])}",
        channel: :cli,
        plan_mode: false,
        working_dir: "/tmp",
        provider: :ollama,
        model: model,
        messages: [%{role: "user", content: "hello"}]
      })

    system.content
  end
end
