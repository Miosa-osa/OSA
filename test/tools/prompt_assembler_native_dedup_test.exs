defmodule OptimalSystemAgent.Tools.PromptAssemblerNativeDedupTest do
  @moduledoc """
  The tool documentation was being sent TWICE on every single request.

  A provider with a native tool channel receives, in the request body, one
  entry per tool carrying that tool's `name`, `description/0`, and
  `parameters/0`. `Soul.ToolsSection` then rendered the SAME tools a second
  time as prose into `{{TOOL_DEFINITIONS}}`, inside the cached system prompt —
  each tool's `prompt/1` body (which for every shipped tool is exactly its
  `description/0`) plus a `Parameters:` line that is `parameters/0` re-encoded.

  Measured on the live registry at the time this was written: 36 of 37 active
  tools had their description reproduced byte-for-byte, 36,294 bytes of it,
  plus 22,178 bytes of re-encoded parameter schemas — out of a 61,185-byte
  prose block. The duplication was ~14.7k tokens on every request.

  The fix subtracts the duplicated SPANS rather than assuming the whole body is
  a duplicate, so a tool whose `prompt/1` says MORE than its `description/0`
  keeps the surplus. And it is conditional on the transport: `claude_cli` and
  `copilot_cli` fold the tool list into prompt TEXT, so for them the prose is
  the only channel there is and nothing may be dropped.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Context
  alias OptimalSystemAgent.Providers.Registry, as: ProviderRegistry
  alias OptimalSystemAgent.Tools.PromptAssembler
  alias OptimalSystemAgent.Tools.Registry, as: ToolRegistry
  alias OptimalSystemAgent.Tools.UseContext

  # ── Fixtures: three shapes of tool ──────────────────────────────────────

  # The shape EVERY shipped tool has today: prompt/1 renders exactly
  # description/0, so the whole prose block is a duplicate.
  defmodule EchoTool do
    def name, do: "echo_tool"
    def aliases, do: ["echo"]
    def search_hint, do: "echo"
    def description, do: "Echoes a string back to the caller."
    def prompt(_opts), do: description()
    def parameters, do: %{"type" => "object", "properties" => %{"s" => %{"type" => "string"}}}
    def should_defer?, do: false
    def always_load?, do: true
  end

  # A tool whose prompt/1 is a SUPERSET of its description: the extra sections
  # exist nowhere in the native schema and must survive the cut.
  defmodule RicherTool do
    def name, do: "richer_tool"
    def aliases, do: []
    def search_hint, do: "richer"
    def description, do: "Does the richer thing."

    def prompt(_opts) do
      """
      #{description()}

      WHEN TO USE: only after echo_tool has run.
      Examples:
        richer_tool(mode: "fast")
      """
    end

    def parameters, do: %{"type" => "object", "properties" => %{"mode" => %{"type" => "string"}}}
    def should_defer?, do: false
    def always_load?, do: true
  end

  # A tool the transport will NOT carry natively. Nothing about it may change.
  defmodule OnlyProseTool do
    def name, do: "only_prose_tool"
    def aliases, do: []
    def search_hint, do: "prose"
    def description, do: "Never appears in the native tools array."
    def prompt(_opts), do: description()
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def should_defer?, do: false
    def always_load?, do: true
  end

  @mods [EchoTool, RicherTool, OnlyProseTool]

  defp ctx, do: UseContext.new(%{}, tools: @mods, agents: [])

  defp assemble(opts) do
    {loaded, _deferred} = PromptAssembler.assemble(@mods, ctx(), opts)
    loaded
  end

  # ── 1. The duplication is actually removed ──────────────────────────────

  describe "native_schema_names option" do
    test "drops the description span carried by the native tool definitions" do
      natives = MapSet.new(["echo_tool", "richer_tool", "only_prose_tool"])

      assert assemble([]) =~ EchoTool.description()

      refute assemble(native_schema_names: natives) =~ EchoTool.description(),
             "the description is in the request's tool definitions; sending it again " <>
               "in the system prompt is the duplication this change exists to remove"
    end

    test "drops the re-encoded Parameters line" do
      natives = MapSet.new(["echo_tool", "richer_tool", "only_prose_tool"])

      assert assemble([]) =~ "Parameters: "
      refute assemble(native_schema_names: natives) =~ "Parameters: "
    end

    test "a tool fully covered by its native schema contributes no block at all" do
      natives = MapSet.new(["echo_tool"])
      out = assemble(native_schema_names: natives)

      refute out =~ "## echo_tool",
             "echo_tool's prompt/1 is exactly its description/0, which the native " <>
               "schema already carries — there is nothing left to say about it"
    end
  end

  # ── 2. Nothing that exists ONLY in the prose is lost ────────────────────

  describe "information preservation" do
    test "keeps every section of prompt/1 that the description does not cover" do
      natives = MapSet.new(["echo_tool", "richer_tool"])
      out = assemble(native_schema_names: natives)

      assert out =~ "## richer_tool"
      assert out =~ "WHEN TO USE: only after echo_tool has run."
      assert out =~ ~S|richer_tool(mode: "fast")|

      refute out =~ RicherTool.description(),
             "only the duplicated span goes; the surplus stays"
    end

    test "a tool absent from the native array is rendered in full" do
      natives = MapSet.new(["echo_tool", "richer_tool"])
      out = assemble(native_schema_names: natives)

      assert out =~ "## only_prose_tool"
      assert out =~ OnlyProseTool.description()

      assert out =~ "Parameters: " <> Jason.encode!(OnlyProseTool.parameters()),
             "a tool the transport will not carry natively keeps its schema in the prose"
    end

    test "without the option every tool renders exactly as before" do
      out = assemble([])

      for mod <- @mods do
        assert out =~ "## #{mod.name()}"
        assert out =~ mod.description()
        assert out =~ "Parameters: " <> Jason.encode!(mod.parameters())
      end
    end
  end

  # ── 3. The transport capability, not a provider-name allowlist ──────────

  describe "Providers.Registry.native_tool_schemas?/1" do
    test "true for providers that put schemas in the request body" do
      for provider <- [:anthropic, :google, :cohere, :bedrock, :ollama, :openai_codex] do
        assert ProviderRegistry.native_tool_schemas?(provider),
               "#{provider} sends a native tools field"
      end
    end

    test "true for every OpenAI-compatible provider" do
      for provider <- [:openai, :groq, :deepseek, :openrouter, :mistral, :xai] do
        assert ProviderRegistry.native_tool_schemas?(provider)
      end
    end

    test "FALSE for the CLI transports, which fold tools into prompt text" do
      # ClaudeCli.build_system_prompt(system, tools) — the tool list becomes
      # part of the system prompt string. Drop the prose there and the model
      # is told about no tools at all.
      refute ProviderRegistry.native_tool_schemas?(:claude_cli)
      refute ProviderRegistry.native_tool_schemas?(:copilot_cli)
    end

    test "FALSE for a provider with no tool channel, and for unknown providers" do
      refute ProviderRegistry.native_tool_schemas?(:replicate)
      refute ProviderRegistry.native_tool_schemas?(:not_a_provider)
      refute ProviderRegistry.native_tool_schemas?("anthropic")
    end
  end

  # ── 4. Variant selection + the revert switch ────────────────────────────

  describe "Agent.Context.static_base_variant/2" do
    setup do
      prev = Application.get_env(:optimal_system_agent, :dedupe_native_tool_prompt)

      on_exit(fn ->
        Application.put_env(:optimal_system_agent, :dedupe_native_tool_prompt, prev)
      end)

      :ok
    end

    test "native transports get the de-duplicated base" do
      Application.put_env(:optimal_system_agent, :dedupe_native_tool_prompt, true)
      assert Context.static_base_variant(:anthropic, false) == :native_tools
      assert Context.static_base_variant(:groq, false) == :native_tools
    end

    test "prompt-text transports keep the full base" do
      Application.put_env(:optimal_system_agent, :dedupe_native_tool_prompt, true)
      assert Context.static_base_variant(:claude_cli, false) == :full
      assert Context.static_base_variant(:copilot_cli, false) == :full
      assert Context.static_base_variant(:replicate, false) == :full
    end

    test "the lite path is untouched and wins over the cut" do
      Application.put_env(:optimal_system_agent, :dedupe_native_tool_prompt, true)

      assert Context.static_base_variant(:ollama, true) == :lite,
             "on the lite path ToolFilter separately caps the native array, so the " <>
               "prose and the array describe different sets and nothing may be dropped"
    end

    test "the config flag reverts everything without a code change" do
      Application.put_env(:optimal_system_agent, :dedupe_native_tool_prompt, false)
      assert Context.static_base_variant(:anthropic, false) == :full
      assert Context.static_base_variant(:groq, false) == :full
    end
  end

  # ── 5. Request-body level proof against the LIVE registry ───────────────

  describe "live registry" do
    test "the native prose loses nothing that the tools array does not carry" do
      active = ToolRegistry.list_active()
      names = MapSet.new(active, & &1.name)
      by_name = Map.new(active, &{&1.name, &1})

      mods =
        :persistent_term.get({ToolRegistry, :builtin_tools}, %{})
        |> Enum.reject(fn {n, _} -> MapSet.member?(ToolRegistry.model_hidden(), n) end)
        |> Enum.map(fn {_, m} -> m end)

      assert mods != [], "registry must be populated for this proof to mean anything"

      live_ctx = UseContext.new(%{}, tools: mods, agents: [])
      {full, _} = PromptAssembler.assemble(mods, live_ctx, [])
      {native, _} = PromptAssembler.assemble(mods, live_ctx, native_schema_names: names)

      assert byte_size(native) < byte_size(full)

      for %{name: name} = tool <- active, MapSet.member?(names, name) do
        # Anything the FULL prose said about this tool is now in exactly one of:
        # the shrunken prose, the array description, or the array parameters.
        assert Map.has_key?(by_name, name)

        assert is_binary(tool.description) and tool.description != "",
               "#{name} would lose its description entirely"

        assert is_map(tool.parameters),
               "#{name} would lose its parameter schema entirely"
      end
    end

    test "a prose tool absent from the tools array keeps its FULL documentation" do
      # The prose set and the array are not identical. `PromptAssembler` gates on
      # `available?/0` while `Registry.list_tools_direct/0` applies the registry's
      # own `tool_available?/1`, so a tool can be documented in the prompt and yet
      # never sent as a schema — `computer_use` is one, depending on host support.
      #
      # That is exactly the case where blanket deletion would destroy a tool's
      # ONLY documentation. Membership is therefore read per tool from
      # `list_active/0`, and anything outside it renders untouched.
      names = MapSet.new(ToolRegistry.list_active(), & &1.name)

      mods =
        :persistent_term.get({ToolRegistry, :builtin_tools}, %{})
        |> Enum.reject(fn {n, _} -> MapSet.member?(ToolRegistry.model_hidden(), n) end)
        |> Enum.map(fn {_, m} -> m end)

      live_ctx = UseContext.new(%{}, tools: mods, agents: [])

      # Same availability gate `assemble/3` applies before partitioning, so the
      # set compared here is the set that actually renders.
      available =
        Enum.filter(mods, fn m ->
          not function_exported?(m, :available?, 0) or m.available?()
        end)

      {loaded, _deferred} = PromptAssembler.partition(available, nil)
      {native, _} = PromptAssembler.assemble(mods, live_ctx, native_schema_names: names)

      orphans = Enum.reject(loaded, &MapSet.member?(names, &1.name()))

      for mod <- orphans do
        assert native =~ "## #{mod.name()}",
               "#{mod.name()} is not in the tools array; dropping its prose would " <>
                 "delete its only documentation"

        assert native =~ mod.description()
        assert native =~ "Parameters: " <> Jason.encode!(mod.parameters())
      end
    end

    test "every tool the array DOES carry has its duplicated spans removed" do
      names = MapSet.new(ToolRegistry.list_active(), & &1.name)

      mods =
        :persistent_term.get({ToolRegistry, :builtin_tools}, %{})
        |> Enum.reject(fn {n, _} -> MapSet.member?(ToolRegistry.model_hidden(), n) end)
        |> Enum.map(fn {_, m} -> m end)

      live_ctx = UseContext.new(%{}, tools: mods, agents: [])
      {full, _} = PromptAssembler.assemble(mods, live_ctx, [])
      {native, _} = PromptAssembler.assemble(mods, live_ctx, native_schema_names: names)

      available =
        Enum.filter(mods, fn m ->
          not function_exported?(m, :available?, 0) or m.available?()
        end)

      {loaded, _} = PromptAssembler.partition(available, nil)
      deduped = Enum.filter(loaded, &MapSet.member?(names, &1.name()))

      assert length(deduped) > 20,
             "expected the bulk of the toolbox to be natively carried; got #{length(deduped)}"

      for mod <- deduped do
        desc = mod.description()
        params_line = "Parameters: " <> Jason.encode!(mod.parameters())

        assert full =~ desc, "precondition: the old prose carried #{mod.name()}'s description"
        assert full =~ params_line

        refute native =~ desc,
               "#{mod.name()}'s description is still duplicated into the system prompt"

        refute native =~ params_line,
               "#{mod.name()}'s parameter schema is still duplicated into the system prompt"
      end
    end
  end
end
