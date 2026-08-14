defmodule OptimalSystemAgent.Security.TerminalEscapeSecondarySurfacesTest do
  @moduledoc """
  The render sites `terminal_escape_render_test.exs` did not cover.

  That test closed the main CLI path — the model-text sink, the markdown and
  diff renderers, the spinner and the permission dialog. Its own commit message
  listed what it left open, in the same injection class and reachable by the
  same payloads:

    * `Channels.CLI.Events` — background-agent and compaction notices, whose
      `role`/`result`/`error`/`reason` are sub-agent and tool output, plus the
      task checklist those handlers print and the spinner status line they
      populate through `:cli_signal_cache`,
    * `/copy` — **the sharpest one**. It prints the last assistant reply so the
      TUI can put it on the operator's clipboard, which turns an `ESC ] 52 ; c ;
      <base64> BEL` in model output into a clipboard write nobody authorised:
      the operator's next paste, possibly into a shell, is attacker-chosen,
    * `Channels.CLI.PlanReview` — a consent gate. The plan is model-authored and
      the operator approves what the box appears to say,
    * `Channels.CLI.AgentTree` — agent roles are names the model picks,
    * `CLI.Remote` — remote stdout, remote agent answers, broker host inventory
      and broker error strings, all straight off the network,
    * `mix osa.run` — headless, so it is what CI and shell pipelines call, and
      nobody is watching the screen.

  Each surface gets two proofs, because either one alone is worthless: the
  attack is neutralised, AND the legitimate render (colour, layout, real
  newlines) still works. A sanitizer that eats OSA's own SGR passes the first
  and fails the operator — the earlier commit hit exactly that when it scrubbed
  after rendering instead of before.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.Agent.Tasks.Tracker.Task
  alias OptimalSystemAgent.CLI.Remote
  alias OptimalSystemAgent.Channels.CLI.{AgentTree, Commands, Events, PlanReview, TaskDisplay}

  @moduletag :security

  @esc "\e"
  @bel "\a"

  # Same battery as the first test, so a surface cannot be "fixed" against a
  # weaker payload than the one already on file.
  @payloads [
    {"OSC 0 title rewrite", "#{@esc}]0;PWNED#{@bel}"},
    {"OSC 52 clipboard write", "#{@esc}]52;c;cm0gLXJmIH4=#{@bel}"},
    {"CSI absolute cursor move", "#{@esc}[9;30H"},
    {"CSI erase display", "#{@esc}[2J"},
    {"CSI alternate screen buffer", "#{@esc}[?1049h"},
    {"CSI device-attributes query (reply lands on stdin)", "#{@esc}[c"},
    {"CSI cursor-position report (reply lands on stdin)", "#{@esc}[6n"},
    {"C1 CSI introducer (U+009B)", "\u009B[31m"},
    {"carriage-return overwrite of a line already printed", "safe\rAPPROVED"}
  ]

  defp payload_line do
    Enum.map_join(@payloads, " ", fn {label, raw} -> "#{label}: #{raw}" end)
  end

  defp payload_block do
    Enum.map_join(@payloads, "\n", fn {label, raw} -> "#{label}: #{raw}" end)
  end

  # OSA emits its own SGR, so "contains no ESC" is the wrong assertion — it
  # would fail on legitimate colour and prove nothing about the attack. Remove
  # the sequences OSA is allowed to emit (`ESC [ … m`, which can only recolour:
  # it cannot move the cursor, query the terminal, or address the clipboard) and
  # nothing escape-shaped may remain.
  @sgr ~r/\e\[[0-9;]*m/

  defp residual_controls(output) do
    output
    |> String.replace(@sgr, "")
    |> String.to_charlist()
    |> Enum.filter(fn cp ->
      cp == 0x1B or cp == 0x07 or cp == 0x0D or (cp < 0x20 and cp != ?\n and cp != ?\t) or
        (cp >= 0x7F and cp <= 0x9F)
    end)
  end

  defp refute_payload_survives(output, context) do
    leftover = residual_controls(output)

    assert leftover == [],
           """
           #{context}: control characters survived to the terminal.

           after removing OSA's own SGR, these control codepoints remain:
             #{inspect(leftover)}

           emitted bytes:
             #{inspect(output, limit: :infinity, printable_limit: 4000)}
           """

    for {label, raw} <- @payloads do
      refute String.contains?(output, raw),
             """
             #{context}: #{label} survived intact.
             forbidden bytes: #{inspect(raw)}
             emitted bytes:   #{inspect(output, limit: :infinity, printable_limit: 4000)}
             """
    end
  end

  # Surfaces that must keep one record on one row are held to the stricter
  # property: no newline at all beyond the ones the renderer itself writes.
  defp refute_extra_lines(output, expected_lines, context) do
    actual = output |> String.trim_trailing("\n") |> String.split("\n") |> length()

    assert actual == expected_lines,
           "#{context}: expected #{expected_lines} line(s), got #{actual} — " <>
             "untrusted text forged rows. #{inspect(output, printable_limit: 2000)}"
  end

  # ── 1. Channels.CLI.Events ───────────────────────────────────────────

  describe "Channels.CLI.Events — background agent and compaction notices" do
    test "a sub-agent's role, result and id cannot drive the terminal" do
      out = Events.background_completed_lines(payload_line(), payload_block(), 4200)
      refute_payload_survives(out, "Events.background_completed_lines/3")
    end

    test "a sub-agent's failure text cannot drive the terminal" do
      out = Events.background_failed_lines(payload_line(), payload_block(), 900)
      refute_payload_survives(out, "Events.background_failed_lines/3")
    end

    test "a started notice cannot drive the terminal" do
      out = Events.background_started_line(payload_line(), payload_line())
      refute_payload_survives(out, "Events.background_started_line/2")
    end

    test "a swarm id cannot drive the terminal" do
      out = Events.swarm_started_line("#{@esc}]0;PWNED#{@bel}deadbeef")
      refute_payload_survives(out, "Events.swarm_started_line/1")
    end

    test "a compaction failure reason cannot drive the terminal" do
      out = Events.compaction_failed_line(payload_line(), 1500)
      refute_payload_survives(out, "Events.compaction_failed_line/2")
    end

    test "a role cannot forge the lines around it, nor close its own quotes" do
      out =
        Events.background_completed_lines(
          "researcher\"\n  ✓ Background agent \"admin\" completed",
          "fine",
          10
        )

      # The notice is exactly: a leading blank, the headline, the preview. The
      # forged text is not deleted — inert residue is the deliberate outcome, so
      # the operator can see something was there — but it is folded onto the row
      # it was already on rather than becoming a row of its own.
      refute_extra_lines(out, 3, "Events.background_completed_lines/3")

      refute out =~ "\"admin\"",
             "a role closed its quote and finished the sentence in OSA's voice"
    end

    test "legitimate notices keep their text, their colour and their timing" do
      out = Events.background_completed_lines("researcher", "found 3 call sites", 4200)

      assert out =~ "researcher"
      assert out =~ "found 3 call sites"
      assert out =~ "Background agent"
      assert String.contains?(out, IO.ANSI.green()), "the success colour was lost"
      assert String.contains?(out, IO.ANSI.faint()), "the dim detail styling was lost"

      failed = Events.background_failed_lines("implementer", "timeout after 60s", 60_000)
      assert failed =~ "implementer"
      assert failed =~ "timeout after 60s"
      assert String.contains?(failed, IO.ANSI.yellow())

      assert Events.swarm_started_line("deadbeefcafe") =~ "deadbeef"
      assert Events.background_started_line("reviewer", "ag_123") =~ "ag_123"
      assert Events.compaction_failed_line("provider refused", 30) =~ "provider refused"
    end
  end

  describe "Channels.CLI.TaskDisplay — the checklist those handlers print" do
    defp task(attrs) do
      struct(
        Task,
        Keyword.merge([id: "t1", title: "Test task", status: :pending, tokens_used: 0], attrs)
      )
    end

    test "render_inline/1 cannot be driven by a model-authored task title" do
      # This path has no width budget to clip a title, so it was the one that
      # put the title on the terminal completely untouched.
      out = TaskDisplay.render_inline([task(title: payload_line())])
      refute_payload_survives(out, "TaskDisplay.render_inline/1")
      refute_extra_lines(out, 1, "TaskDisplay.render_inline/1")
    end

    test "render/2 cannot be driven by a title that fits inside the box" do
      # `CLI.Width.fit/2` measures with `strip_ansi/1` but returns the ORIGINAL
      # string, so a short escape passes straight through it — the same
      # count-the-columns-and-discard-the-result shape as the original bug.
      out = TaskDisplay.render([task(title: "ok#{@esc}[2J#{@esc}]52;c;eA==#{@bel}")])
      refute_payload_survives(out, "TaskDisplay.render/2")
    end

    test "legitimate titles, icons and colour survive" do
      out = TaskDisplay.render_inline([task(title: "Write the migration", status: :completed)])
      assert out =~ "Write the migration"
      assert out =~ "✔"
      assert String.contains?(out, IO.ANSI.green())

      box = TaskDisplay.render([task(title: "Write the migration")])
      assert box =~ "Write the migration"
      assert box =~ "┌"
      assert box =~ "│"
    end
  end

  # ── 2. /copy — the clipboard path ────────────────────────────────────

  describe "/copy" do
    defp assistant(text), do: [%{role: "assistant", content: text}]

    test "an OSC 52 in the reply cannot reach the clipboard" do
      {:ok, out} = Commands.copy_payload(assistant(payload_block()))
      refute_payload_survives(out, "Commands.copy_payload/1")

      refute String.contains?(out, "#{@esc}]52;c;"),
             "the clipboard-write sequence survived into the copied text"
    end

    test "the same holds for a structured content list" do
      messages = [
        %{"role" => "assistant", "content" => [%{"text" => payload_block()}]}
      ]

      {:ok, out} = Commands.copy_payload(messages)
      refute_payload_survives(out, "Commands.copy_payload/1 (list content)")
    end

    test "it copies the LAST assistant reply, scrubbed, with its newlines intact" do
      messages = [
        %{role: "assistant", content: "an older reply"},
        %{role: "user", content: "and then?"},
        %{role: "assistant", content: "line one\nline two\n\tindented"}
      ]

      assert {:ok, "line one\nline two\n\tindented"} = Commands.copy_payload(messages)
    end

    test "no assistant reply yields :empty rather than an empty copy" do
      assert Commands.copy_payload([]) == :empty
      assert Commands.copy_payload([%{role: "user", content: "hi"}]) == :empty
      assert Commands.copy_payload(assistant("   ")) == :empty
    end

    test "cmd_copy/2 prints exactly copy_payload/1's bytes" do
      # Guard against the fix living in the extracted function while the caller
      # keeps its own raw path — the shape of the original bug.
      source = File.read!("lib/optimal_system_agent/channels/cli/commands.ex")

      [_, body] = String.split(source, "def cmd_copy(_args, session_id) do", parts: 2)
      [body, _] = String.split(body, "\n  end\n", parts: 2)

      assert body =~ "copy_payload",
             "cmd_copy/2 no longer routes through copy_payload/1"

      refute body =~ "extract_text",
             "cmd_copy/2 grew a second, unscrubbed extraction path"
    end
  end

  # ── 3. PlanReview — a consent gate ───────────────────────────────────

  describe "Channels.CLI.PlanReview" do
    test "a model-authored plan cannot repaint the box it is being approved in" do
      out = capture_io(fn -> PlanReview.render_plan_box(payload_block()) end)
      refute_payload_survives(out, "PlanReview.render_plan_box/1")
    end

    test "the box, its title and the plan's own markdown still render" do
      out = capture_io(fn -> PlanReview.render_plan_box("Add **caching** to the resolver") end)

      assert out =~ "Plan"
      assert out =~ "┌"
      assert out =~ "└"
      assert out =~ "caching"
      assert String.contains?(out, IO.ANSI.bright()), "markdown bold was lost inside the box"
    end
  end

  # ── 4. AgentTree ─────────────────────────────────────────────────────

  describe "Channels.CLI.AgentTree" do
    test "a model-chosen agent role cannot drive the terminal" do
      out =
        capture_io(fn ->
          AgentTree.render([
            %{
              id: "root",
              role: payload_line(),
              status: :running,
              children: [%{id: "c1", role: payload_line(), status: :failed, children: []}]
            }
          ])
        end)

      refute_payload_survives(out, "AgentTree.render/1")
    end

    test "a role cannot forge sibling agents that do not exist" do
      out =
        capture_io(fn ->
          AgentTree.render([
            %{id: "root", role: "coordinator\n    ├── ✓ auditor (approved)", status: :running}
          ])
        end)

      # blank, "Agent Hierarchy:", the single root row — and nothing else. The
      # forged text survives as inert residue on the root's own row (that is the
      # point: the operator sees it), but it is not a node.
      refute_extra_lines(out, 3, "AgentTree.render/1")

      # The forged connector is now just text in the middle of the real node's
      # label, which is what a dropped `\n` reduces it to.
      [_blank, _header, row] = String.split(String.trim_trailing(out, "\n"), "\n")

      assert String.starts_with?(row, "  └── "),
             "the real node lost its own connector: #{inspect(row)}"
    end

    test "the tree still renders roles, connectors, icons and stats" do
      out =
        capture_io(fn ->
          AgentTree.render([
            %{
              id: "root",
              role: "coordinator",
              status: :running,
              children: [
                %{
                  id: "c1",
                  role: "researcher",
                  status: :completed,
                  children: [],
                  stats: %{tools: 4, tokens: 8200}
                }
              ]
            }
          ])
        end)

      assert out =~ "Agent Hierarchy:"
      assert out =~ "coordinator"
      assert out =~ "researcher"
      assert out =~ "└──"
      assert out =~ "4 tools"
      assert out =~ "8.2k"
      assert String.contains?(out, IO.ANSI.green()), "the completed icon lost its colour"
    end
  end

  # ── 5. CLI.Remote ────────────────────────────────────────────────────

  describe "CLI.Remote" do
    test "a broker-supplied host name or OS string cannot drive the terminal" do
      out = Remote.host_line(%{name: payload_line(), online: true, os_kind: payload_line()})
      refute_payload_survives(out, "Remote.host_line/1")
      refute_extra_lines(out, 1, "Remote.host_line/1")
    end

    test "a host name cannot forge another host's row or status" do
      out = Remote.host_line(%{name: "laptop\n  prod-db  [online]  linux", online: false})

      # One host, one row. The forged text is still legible (inert residue is
      # deliberate) but it cannot be a second entry in the table, and the real
      # status is still the last thing on the row.
      refute_extra_lines(out, 1, "Remote.host_line/1")

      assert String.ends_with?(out, "[offline]  "),
             "the real status is no longer the row's own trailing field"
    end

    test "a broker error string cannot drive the terminal" do
      out = Remote.error_line("Error: #{payload_line()}")
      refute_payload_survives(out, "Remote.error_line/1")
      refute_extra_lines(out, 1, "Remote.error_line/1")
    end

    test "the host table and error text still read correctly" do
      assert Remote.host_line(%{name: "laptop", online: true, os_kind: "darwin"}) ==
               "  laptop  [online]  darwin"

      assert Remote.host_line(%{id: "h_42", online: false}) == "  h_42  [offline]  "
      assert Remote.host_line(%{online: true}) =~ "(unknown)"
      assert Remote.error_line("Error: token missing") == "Error: token missing"
    end

    test "remote stdout is emitted through the block tier, not raw" do
      source = File.read!("lib/optimal_system_agent/cli/remote.ex")

      refute source =~ ~r/\n\s+IO\.puts\(text\)/,
             "a remote result is still being printed unscrubbed"

      assert source =~ "IO.puts(Sanitize.scrub_block(text))"
    end
  end

  # ── 6. mix osa.run ───────────────────────────────────────────────────

  describe "mix osa.run" do
    test "the text format cannot put a payload on a CI machine's terminal" do
      out = Mix.Tasks.Osa.Run.text_output(payload_block())
      refute_payload_survives(out, "Mix.Tasks.Osa.Run.text_output/1")
    end

    test "the text format keeps the answer, its newlines and its tabs" do
      assert Mix.Tasks.Osa.Run.text_output("first\nsecond\n\tthird") == "first\nsecond\n\tthird"
    end

    test "the json formats are inert on a terminal without losing a byte" do
      # These are a machine-readable contract, so the content is NOT scrubbed —
      # it is escaped. Both halves have to hold: nothing the terminal acts on,
      # and an exact round-trip for the consumer.
      line = Mix.Tasks.Osa.Run.json_line(%{type: "result", content: payload_block()})

      refute_payload_survives(line, "Mix.Tasks.Osa.Run.json_line/1")

      assert line == for(<<c <- line>>, c < 0x80, into: "", do: <<c>>),
             "json_line/1 emitted a non-ASCII byte, so the C1 range can still reach the terminal"

      assert %{"type" => "result", "content" => decoded} = Jason.decode!(line)

      assert decoded == payload_block(),
             "the machine-readable contract lost or altered the model's bytes"
    end

    test "json_line/1 round-trips ordinary unicode too" do
      line = Mix.Tasks.Osa.Run.json_line(%{content: "héllo — 世界 🌍"})
      assert Jason.decode!(line)["content"] == "héllo — 世界 🌍"
    end
  end
end
