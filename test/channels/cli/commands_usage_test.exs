defmodule OptimalSystemAgent.Channels.CLI.CommandsUsageTest do
  @moduledoc """
  `/usage` as a command surface, and the cost surfaces it sits next to.

  `/cost` is included here because it is the thing `/usage` had to be kept
  distinct from: for a long time `/cost` read `Budget.get_status/0` — which
  returns `{:ok, map}` — as a bare map, so the `Access` call raised inside its
  own `try` and every invocation printed "No cost data available" whether or
  not there was any. A regression back to that shape is invisible from the
  outside, so it is asserted from the inside.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Channels.CLI.Commands

  @sid "usage-cmd-test"

  describe "registration" do
    test "/usage is registered, described, and offered to autocomplete" do
      assert "usage" in Commands.list()

      {_name, desc} =
        Enum.find(Commands.list_with_descriptions(), fn {n, _} -> n == "usage" end)

      # The description must not read like a context-window meter: that is
      # `/context`, and conflating the two is the exact confusion this
      # command was added to remove.
      assert desc =~ "quota"
      refute desc =~ "context window"
    end

    test "/cost is still registered alongside it" do
      assert "cost" in Commands.list()
    end
  end

  describe "/usage" do
    test "renders the heading and returns the session id" do
      out = capture_io(fn -> assert @sid == Commands.dispatch("usage", @sid) end)

      assert out =~ "Usage"
    end

    # The provider's-own-report heading is asserted against `Render.lines/2`
    # with an explicit report rather than against dispatched output.
    #
    # Not a weakening — the opposite. `Usage.report/1` derives its entries from
    # whichever provider is configured *at the moment it runs*, and this suite
    # is `async: false` alongside other suites that put and delete provider env
    # vars. So the dispatched output legitimately alternated between the
    # configured rendering and the "No provider is configured yet" branch
    # depending on test order, and the assertion was failing for a reason that
    # had nothing to do with `/usage`. Feeding the pure renderer a known report
    # pins the exact string unconditionally, which is what the module was split
    # this way for (see its moduledoc); the dispatch test above keeps the
    # end-to-end claims that ARE order-independent.
    test "the provider's own report gets its own heading, distinct from OSA's measurement" do
      report = %{
        active: "anthropic",
        entries: [
          %{
            provider: "anthropic",
            display_name: "Anthropic",
            active?: true,
            auth_mode: :api_key,
            account: %{status: :not_connected},
            measured: %{input_tokens: 0, output_tokens: 0}
          }
        ]
      }

      out = Enum.join(OptimalSystemAgent.Usage.Render.lines(report), "\n")

      assert out =~ "Usage"
      assert out =~ "as reported by the provider"
    end

    test "`/usage all` widens the view without changing the session" do
      out = capture_io(fn -> assert @sid == Commands.dispatch("usage all", @sid) end)
      assert out =~ "Usage"
      # The "showing only the active provider" footer is dropped in all-mode.
      refute out =~ "shows every configured one"
    end

    test "never prints a bare zero quota" do
      out = capture_io(fn -> Commands.dispatch("usage", @sid) end)
      refute out =~ "0%"
    end
  end

  describe "/cost still works" do
    test "prints a real breakdown rather than the failure fallback" do
      out = capture_io(fn -> assert @sid == Commands.dispatch("cost", @sid) end)

      assert out =~ "Cost Summary"
      refute out =~ "No cost data available"
      # And it points at the other number rather than pretending to be it.
      assert out =~ "/usage"
    end
  end

  describe "/status still works" do
    test "renders the session block including a cost line" do
      out = capture_io(fn -> assert @sid == Commands.dispatch("status", @sid) end)

      assert out =~ "Session Status"
      assert out =~ "Cost:"
      assert out =~ "OSA-measured"
    end
  end
end
