defmodule OptimalSystemAgent.Agent.AskUserModeTest do
  @moduledoc """
  The `ask_user` gate.

  The failure being prevented is specific and was reported from a real run: a
  long-running session calls `ask_user`, blocks for five minutes on a question
  nobody is present to answer, and does nothing until the timeout — then asks
  again. These tests pin the three things that make that impossible:

    1. off is the default, in every context, with no attended/unattended
       special case;
    2. off means the tool is not in the array AND a call that arrives anyway is
       answered with an instruction rather than a block;
    3. the array is byte-stable across the requests of a session, so the gate
       does not cost the prompt cache anything it was not already spending.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Agent.AskUserMode
  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Agent.Loop.ToolFilter
  alias OptimalSystemAgent.Channels.HTTP.API.ToolRoutes
  alias OptimalSystemAgent.Tools.Builtins.AskUser.Handler
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    prev_env = System.get_env("OSA_ASK_USER")
    System.delete_env("OSA_ASK_USER")

    on_exit(fn ->
      if prev_env, do: System.put_env("OSA_ASK_USER", prev_env)
    end)

    {:ok, session_id: "ask-user-#{System.unique_integer([:positive])}"}
  end

  defp tools, do: Enum.map(~w(file_read ask_user shell_execute), &%{name: &1})
  defp names(list), do: Enum.map(list, & &1.name)

  # ── Default ───────────────────────────────────────────────────────────

  describe "the default" do
    test "is off with nothing configured", %{session_id: sid} do
      refute AskUserMode.enabled?(sid)
      refute AskUserMode.default_enabled?()
    end

    test "is off for an unknown session and for no session at all" do
      refute AskUserMode.enabled?(nil)
      refute AskUserMode.enabled?("never-seen-#{System.unique_integer([:positive])}")
    end

    test "does not vary by channel — there is one default, not two" do
      # The whole point of the decision: a headless run and an attended TUI
      # session resolve identically. If this ever forks, the operator can no
      # longer predict what a session will do from what they configured.
      for channel <- [:cli, :headless, :internal, :http, :scheduler] do
        sid = "chan-#{channel}-#{System.unique_integer([:positive])}"
        refute AskUserMode.enabled?(sid), "#{channel} resolved to a different default"
      end
    end
  end

  # ── Toggling, both directions ─────────────────────────────────────────

  describe "the sticky per-session flag" do
    test "turns on and back off", %{session_id: sid} do
      refute AskUserMode.enabled?(sid)

      :ok = AskUserMode.put(sid, true)
      assert AskUserMode.enabled?(sid)

      :ok = AskUserMode.put(sid, false)
      refute AskUserMode.enabled?(sid)
    end

    test "an explicit off beats an enabling env var", %{session_id: sid} do
      System.put_env("OSA_ASK_USER", "1")
      assert AskUserMode.default_enabled?()
      assert AskUserMode.enabled?(sid)

      :ok = AskUserMode.put(sid, false)

      refute AskUserMode.enabled?(sid),
             "a session-level off must win over the ambient default"
    end

    test "is scoped to one session", %{session_id: sid} do
      other = "other-#{System.unique_integer([:positive])}"
      :ok = AskUserMode.put(sid, true)

      assert AskUserMode.enabled?(sid)
      refute AskUserMode.enabled?(other)
    end

    test "clear/1 returns the session to the resolved default", %{session_id: sid} do
      :ok = AskUserMode.put(sid, true)
      assert AskUserMode.enabled?(sid)

      :ok = AskUserMode.clear(sid)
      refute AskUserMode.enabled?(sid)
    end

    test "sticky/1 distinguishes 'not set' from 'set to false'", %{session_id: sid} do
      assert AskUserMode.sticky(sid) == nil
      :ok = AskUserMode.put(sid, false)
      assert AskUserMode.sticky(sid) == false
    end
  end

  describe "the env var" do
    test "enables on truthy values", %{session_id: sid} do
      for v <- ~w(1 true yes on TRUE  On ) do
        System.put_env("OSA_ASK_USER", v)
        assert AskUserMode.enabled?(sid), "#{inspect(v)} should enable"
      end
    end

    test "does not enable on anything else", %{session_id: sid} do
      for v <- ~w(0 false no off nope 2) do
        System.put_env("OSA_ASK_USER", v)
        refute AskUserMode.enabled?(sid), "#{inspect(v)} should not enable"
      end
    end
  end

  # ── The array ─────────────────────────────────────────────────────────

  describe "filter_tools/2" do
    test "removes ask_user when disabled" do
      assert names(AskUserMode.filter_tools(tools(), false)) == ~w(file_read shell_execute)
    end

    test "leaves the list untouched when enabled" do
      assert AskUserMode.filter_tools(tools(), true) == tools()
    end

    test "tolerates string-keyed specs" do
      mixed = [%{"name" => "ask_user"}, %{name: "file_read"}]
      assert [%{name: "file_read"}] = AskUserMode.filter_tools(mixed, false)
    end
  end

  describe "ToolFilter integration" do
    defp filter_state(extra) do
      Map.merge(
        %{
          messages: [],
          provider: :anthropic,
          model: "claude-sonnet-4-5",
          delegation_depth: 0,
          discovered_tools: []
        },
        extra
      )
    end

    test "the gate is applied by the per-request filter" do
      out = ToolFilter.filter(tools(), filter_state(%{ask_user_enabled: false}))
      refute "ask_user" in names(out)
    end

    test "the gate is not applied when enabled" do
      out = ToolFilter.filter(tools(), filter_state(%{ask_user_enabled: true}))
      assert "ask_user" in names(out)
    end

    test "a state with no flag at all resolves to off" do
      # Defensive: `ToolFilter.filter/2` is called with plain maps in several
      # tests and internal paths. A missing key must read as the safe default,
      # not crash and not silently enable.
      out = ToolFilter.filter(tools(), filter_state(%{}))
      refute "ask_user" in names(out)
    end

    test "a tool_search widening cannot smuggle ask_user back in" do
      # `repin_discovered/2` re-appends anything discovery surfaced, AFTER every
      # narrowing pass. Without the gate running last, a model that searched for
      # "ask" would get the tool back mid-session — a gate that stops holding
      # partway through is worse than no gate, because nobody would look again.
      state =
        filter_state(%{
          ask_user_enabled: false,
          discovered_tools: [%{name: "ask_user"}, %{name: "web_search"}]
        })

      out = ToolFilter.filter(tools(), state)

      refute "ask_user" in names(out)
      assert "web_search" in names(out), "the gate must not eat unrelated discoveries"
    end
  end

  describe "prompt-cache stability" do
    test "the array is byte-identical across the requests of a session" do
      # The tool schemas sit at the FRONT of the cached prefix. A gate that
      # re-derived its answer per request — from the env, the settings file, or
      # the clock — would rewrite that prefix whenever the source changed and
      # silently drop the session's cache hit rate. Pinning is what prevents it,
      # so this asserts the pinned value produces a stable array even while the
      # ambient default moves underneath it.
      state = filter_state(%{ask_user_enabled: false})
      first = ToolFilter.filter(tools(), state)

      System.put_env("OSA_ASK_USER", "1")
      second = ToolFilter.filter(tools(), state)

      assert first == second
    end
  end

  # ── The refusal ───────────────────────────────────────────────────────

  describe "a call that arrives while disabled" do
    test "returns immediately instead of blocking", %{session_id: sid} do
      ctx = %UseContext{session_id: sid}

      {elapsed_us, {:ok, text}} =
        :timer.tc(fn -> Handler.execute(%{"question" => "which one?"}, ctx) end)

      # The blocking path waits `Constants.timeout_ms()` (300s). Anything in the
      # same order of magnitude as a millisecond proves we did not enter it.
      assert elapsed_us < 1_000_000, "the disabled path must not block"
      assert is_binary(text)
    end

    test "is answered with something the model can act on", %{session_id: sid} do
      {:ok, text} =
        Handler.execute(%{"question" => "which one?"}, %UseContext{session_id: sid})

      # Three properties, each load-bearing: name the constraint, forbid the
      # retry (or it asks again next iteration), and say what to do instead.
      assert text =~ "disabled"
      assert text =~ "Do not ask again"
      assert text =~ "best assumption"
      assert text =~ "state that assumption"
    end

    test "is an ok result, not an error", %{session_id: sid} do
      # An `{:error, _}` would feed the doom-loop detector and could abort the
      # turn for something that is not a failure — the same reasoning that makes
      # a DECLINED question an ok result.
      assert {:ok, _} =
               Handler.execute(%{"question" => "q"}, %UseContext{session_id: sid})
    end

    test "a headless session with no responder attached does not block" do
      # The reported failure, end to end: no TUI, no PubSub subscriber, nobody
      # to answer. Under the old code this parked for five minutes.
      sid = "headless-#{System.unique_integer([:positive])}"
      refute AskUserMode.enabled?(sid)

      task =
        Task.async(fn ->
          Handler.execute(%{"question" => "proceed?"}, %UseContext{session_id: sid})
        end)

      assert {:ok, text} = Task.await(task, 2_000)
      assert text =~ "best assumption"
    end
  end

  describe "when enabled, the blocking path is restored" do
    test "a call blocks until an answer arrives", %{session_id: sid} do
      :ok = AskUserMode.put(sid, true)
      # AskUserMode is the operator's standing preference; `Agent.Attendance` is
      # the separate question of whether anyone is attached to THIS session right
      # now, and the handler consults both. Declared here because the synthetic
      # session has no channel — the unattended path is covered in
      # test/agent/attendance_test.exs.
      :ok = OptimalSystemAgent.Agent.Attendance.put_override(sid, true)
      on_exit(fn -> OptimalSystemAgent.Agent.Attendance.clear(sid) end)
      parent = self()

      task =
        Task.async(fn ->
          send(parent, :asking)
          Handler.execute(%{"question" => "which one?"}, %UseContext{session_id: sid})
        end)

      assert_receive :asking, 1_000

      # It must still be waiting — the whole feature is that the OPERATOR
      # chooses this, so "on" has to actually mean on.
      refute Task.yield(task, 300)

      send(task.pid, {:ask_user_answer, "survey", "the second one"})

      assert {:ok, text} = Task.await(task, 2_000)
      assert text =~ "the second one"
    end
  end

  # ── The loop's live tool array ────────────────────────────────────────

  describe "the in-place Loop toggle" do
    defp base_tools do
      ~w(file_read shell_execute ask_user delegate) |> Enum.map(&%{name: &1})
    end

    defp loop_state(overrides) do
      struct(
        Loop,
        [session_id: "loop-#{System.unique_integer([:positive])}", all_tools: base_tools()] ++
          overrides
      )
    end

    test "turning it ON puts ask_user back into the live array" do
      state = loop_state(ask_user_enabled: false, tools: base_tools() -- [%{name: "ask_user"}])

      {:reply, {:ok, true}, new} = Loop.handle_call({:set_ask_user, true}, self(), state)

      assert new.ask_user_enabled == true
      assert "ask_user" in names(new.tools)
    end

    test "turning it OFF removes it from the live array" do
      state = loop_state(ask_user_enabled: true, tools: base_tools())

      {:reply, {:ok, false}, new} = Loop.handle_call({:set_ask_user, false}, self(), state)

      assert new.ask_user_enabled == false
      refute "ask_user" in names(new.tools)
      # Everything else survives — this gate removes one tool, not a category.
      assert names(new.tools) == ~w(file_read shell_execute delegate)
    end

    test "it composes with the coordinator toggle instead of clobbering it" do
      # Both toggles rebuild `tools` from the same preserved `all_tools`. If
      # either rebuilt it in isolation, flipping one would silently undo the
      # other — the failure mode of two independent filters writing one field.
      state = loop_state(ask_user_enabled: true, coordinator: false, tools: base_tools())

      {:reply, {:ok, true}, coord_on} =
        Loop.handle_call({:set_coordinator, true}, self(), state)

      assert "ask_user" in names(coord_on.tools), "coordinator mode allows ask_user"
      refute "shell_execute" in names(coord_on.tools), "coordinator mode restricts execution"

      {:reply, {:ok, false}, both} =
        Loop.handle_call({:set_ask_user, false}, self(), coord_on)

      refute "ask_user" in names(both.tools)
      refute "shell_execute" in names(both.tools), "the coordinator restriction survived"
      assert "delegate" in names(both.tools)
    end

    test "get_ask_user reflects the live pinned state" do
      assert {:reply, {:ok, true}, _} =
               Loop.handle_call({:get_ask_user}, self(), loop_state(ask_user_enabled: true))
    end
  end

  # ── The operator-facing surface ───────────────────────────────────────

  describe "POST /execute ask-user arm" do
    @route_opts ToolRoutes.init([])

    defp exec(arg, session_id) do
      conn(
        :post,
        "/execute",
        Jason.encode!(%{command: "ask-user", arg: arg, session_id: session_id})
      )
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      |> ToolRoutes.call(@route_opts)
      |> then(&Jason.decode!(&1.resp_body))
    end

    test "on and off dispatch and report the resulting state", %{session_id: sid} do
      on = exec("on", sid)
      assert on["enabled"] == true
      assert on["command"] == "ask-user"
      assert on["output"] =~ "Questions ON"
      assert AskUserMode.enabled?(sid)

      off = exec("off", sid)
      assert off["enabled"] == false
      assert off["output"] =~ "Questions OFF"
      refute AskUserMode.enabled?(sid)
    end

    test "enabling names the prompt-cache cost instead of absorbing it", %{session_id: sid} do
      # A toggle that quietly changes the tool array — and with it the cached
      # prefix — is exactly the kind of silent behaviour this codebase has been
      # removing. The operator is told, in the same breath as the confirmation.
      assert exec("on", sid)["output"] =~ "prompt cache re-primes once"
    end

    test "an unrecognised verb REPORTS rather than toggles", %{session_id: sid} do
      # Deliberately unlike /coordinator, which toggles on an unknown verb.
      # Whether the agent can interrupt an unattended run is not something to
      # discover by accident.
      assert exec("", sid)["enabled"] == false
      assert exec("wat", sid)["enabled"] == false

      AskUserMode.put(sid, true)
      assert exec("status", sid)["enabled"] == true
      assert AskUserMode.enabled?(sid), "a read must not change the state"
    end

    test "status emits no ask_user_mode event — a read has no side effects", %{
      session_id: sid
    } do
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")

      assert exec("status", sid)["enabled"] == false
      assert exec("", sid)["enabled"] == false

      refute_receive {:osa_event, %{type: :system_event, event: :ask_user_mode}}, 300
    end

    test "a real transition announces, so the TUI can confirm it", %{session_id: sid} do
      Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{sid}")

      assert exec("on", sid)["enabled"] == true

      assert_receive {:osa_event, %{type: :system_event, event: :ask_user_mode, enabled: true}},
                     2000
    end
  end

  describe "the CLI command" do
    test "/ask-user is registered with a handler" do
      commands = OptimalSystemAgent.Channels.CLI.Commands.list()
      assert "ask-user" in commands
    end

    test "a bare /ask-user reports without changing anything", %{session_id: sid} do
      AskUserMode.put(sid, true)

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          OptimalSystemAgent.Channels.CLI.Commands.cmd_ask_user("", sid)
        end)

      assert out =~ "enabled"
      assert AskUserMode.enabled?(sid)
    end

    test "/ask-user off turns it off and says so", %{session_id: sid} do
      AskUserMode.put(sid, true)

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          OptimalSystemAgent.Channels.CLI.Commands.cmd_ask_user("off", sid)
        end)

      assert out =~ "disabled"
      assert out =~ "best assumption"
      refute AskUserMode.enabled?(sid)
    end
  end
end
