defmodule OptimalSystemAgent.Security.TerminalEscapeRenderTest do
  @moduledoc """
  Inbound escape injection: MODEL TEXT and TOOL OUTPUT reaching the operator's
  terminal with their control characters intact.

  This is the render side, and it is a different surface from
  `Utils.WireEncoding`, which scrubs *outbound* provider messages for UTF-8
  validity and never looks at control characters.

  The threat is not cosmetic. A file whose contents OSA reads back, or a string
  the model chooses to emit, can carry:

    * `ESC ] 0 ; … BEL` — rewrites the terminal's title bar,
    * `ESC [ row ; col H` and `ESC [ 2 J` — repositions the cursor and erases,
      which lets output already on screen be overdrawn (a consent prompt can be
      made to read differently from what it is about to approve),
    * `ESC [ ? 1049 h` — swaps to the alternate screen buffer,
    * `ESC ] 52 ; c ; <base64> BEL` — **writes the operator's clipboard**, so
      their next paste is attacker-chosen,
    * `ESC [ c` / `ESC [ 6 n` — device-attribute and cursor-position *queries*.
      The terminal answers these by writing the reply onto the application's
      **stdin**. That is injection into the next prompt: text the operator never
      typed, arriving on the input channel.

  The Rust TUI already defends every display site (`priv/rust/tui/src/render/
  sanitize.rs`, with proofs in `render/injection_proofs.rs`). The Elixir
  plain-CLI path — headless `mix osa.run`, `cli/remote.ex`, and the CLI REPL —
  had no equivalent. `CLI.Width.strip_ansi/1` was the one correct stripper in
  the Elixir tree and it was only ever called by `visible/1`, which measures a
  width and throws the stripped string away.

  Every assertion below is a byte-level measurement of what the render layer
  actually emits.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias OptimalSystemAgent.CLI.Sanitize
  alias OptimalSystemAgent.Channels.CLI.Markdown
  alias OptimalSystemAgent.Channels.CLI.Renderer

  @moduletag :security

  @esc "\e"
  @bel "\a"

  # Each entry is {label, raw payload, the byte signature that must not survive}.
  @payloads [
    {"OSC 0 title rewrite", "#{@esc}]0;PWNED#{@bel}", "]0;PWNED"},
    {"OSC 8 hyperlink to an attacker origin",
     "#{@esc}]8;;http://evil.example/x#{@esc}\\click here#{@esc}]8;;#{@esc}\\",
     "]8;;http://evil.example"},
    {"CSI absolute cursor move", "#{@esc}[9;30H", "[9;30H"},
    {"CSI erase display", "#{@esc}[2J", "[2J"},
    {"CSI alternate screen buffer", "#{@esc}[?1049h", "[?1049h"},
    {"OSC 52 clipboard write", "#{@esc}]52;c;cm0gLXJmIH4=#{@bel}", "]52;c;"},
    {"CSI device-attributes query (reply lands on stdin)", "#{@esc}[c", "#{@esc}[c"},
    {"CSI cursor-position report (reply lands on stdin)", "#{@esc}[6n", "#{@esc}[6n"},
    {"C1 CSI introducer (U+009B)", "\u009B[31m", "\u009B"},
    {"carriage-return overwrite of a line already printed", "safe\rAPPROVED", "\rAPPROVED"}
  ]

  defp fixture_body do
    Enum.map_join(@payloads, "\n", fn {label, raw, _sig} -> "#{label}: #{raw}" end)
  end

  # OSA legitimately emits its own SGR — colour, bold, reset — so "contains no
  # ESC" is the wrong assertion; it would fail on OSA's own styling and say
  # nothing about the attack.
  #
  # The right property is: remove the sequences OSA is *allowed* to emit (SGR,
  # `ESC [ … m`, which only ever changes colour and cannot move the cursor,
  # query the terminal, or address the clipboard) and nothing escape-shaped may
  # be left. Anything remaining is a sequence the payload put there.
  #
  # Note what this deliberately permits: inert residue. Dropping the ESC from
  # `ESC ] 0 ; PWNED BEL` leaves the text `]0;PWNED`, which the terminal prints
  # rather than obeys. That is the intended outcome and matches the Rust tier —
  # the operator sees that something was there.
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

    # And spell out the individual attacks, so a failure names the capability
    # rather than just a byte value.
    for {label, raw, _sig} <- @payloads do
      dangerous = String.replace(raw, @sgr, "")

      if String.contains?(dangerous, "\e") or String.contains?(dangerous, "\a") or
           String.contains?(dangerous, "\r") do
        refute String.contains?(output, dangerous),
               """
               #{context}: #{label} survived intact.
               forbidden bytes: #{inspect(dangerous)}
               emitted bytes:   #{inspect(output, limit: :infinity, printable_limit: 4000)}
               """
      end
    end
  end

  # ── Premise ───────────────────────────────────────────────────────────

  describe "premise" do
    test "a file on disk really can carry these bytes, and file_read hands them back raw" do
      path =
        Path.join(System.tmp_dir!(), "osa_esc_#{System.unique_integer([:positive])}.txt")

      File.write!(path, fixture_body())
      on_exit(fn -> File.rm(path) end)

      body = File.read!(path)

      assert String.contains?(body, "#{@esc}]0;PWNED#{@bel}"),
             "premise failed — the payload did not round-trip through the filesystem"

      assert String.contains?(body, "#{@esc}]52;c;"),
             "premise failed — the OSC 52 clipboard payload did not survive"
    end
  end

  # ── The sanitizer ─────────────────────────────────────────────────────

  describe "CLI.Sanitize" do
    test "drops every payload signature while keeping the legible text" do
      scrubbed = Sanitize.scrub_block(fixture_body())

      refute_payload_survives(scrubbed, "Sanitize.scrub_block/1")

      # Content is neutralized, not deleted — the operator still sees that
      # something was there, exactly as the Rust tier does.
      assert scrubbed =~ "PWNED", "inert residue should remain readable"
      assert scrubbed =~ "OSC 0 title rewrite"
    end

    test "keeps newlines and tabs, which carry real layout" do
      assert Sanitize.scrub_block("a\nb\tc") == "a\nb\tc"
    end

    test "scrub_line/1 additionally drops newlines, so one line cannot become many" do
      out = Sanitize.scrub_line("status: ok\n\rFAKE APPROVED LINE")
      refute String.contains?(out, "\n")
      refute String.contains?(out, "\r")
    end

    test "invisible and bidi codepoints are dropped (Trojan Source)" do
      for cp <- ["\u200B", "\u202E", "\u2066", "\uFEFF", "\u00AD"] do
        refute String.contains?(Sanitize.scrub_block("a" <> cp <> "b"), cp),
               "codepoint #{inspect(cp)} survived"
      end
    end

    test "is idempotent, so a chunk scrubbed twice is unchanged" do
      once = Sanitize.scrub_block(fixture_body())
      assert Sanitize.scrub_block(once) == once
    end

    test "an escape split across streaming chunks is still defanged" do
      # Deltas arrive in arbitrary slices. Because the scrub drops characters
      # rather than parsing whole sequences, a sequence cut in half loses its
      # ESC in whichever chunk holds it and the remainder is inert text.
      full = "#{@esc}]0;PWNED#{@bel}"

      for split <- 1..(String.length(full) - 1) do
        {a, b} = String.split_at(full, split)
        joined = Sanitize.scrub_block(a) <> Sanitize.scrub_block(b)

        refute String.contains?(joined, @esc),
               "ESC survived a split at #{split}: #{inspect(joined)}"
      end
    end

    test "does not raise on odd input" do
      assert Sanitize.scrub_block(nil) == nil
      assert Sanitize.scrub_block(123) == 123
      assert Sanitize.scrub_block("") == ""
    end

    test "invalid UTF-8 is replaced rather than crashing the renderer" do
      out = Sanitize.scrub_block(<<0xFF, 0xFE, "ok">>)
      assert String.valid?(out)
      assert out =~ "ok"
    end
  end

  # ── The render sites ──────────────────────────────────────────────────

  describe "model text on the plain-CLI path" do
    test "Markdown.render/1 does not pass payload escapes through" do
      refute_payload_survives(Markdown.render(fixture_body()), "Markdown.render/1")
    end

    test "Markdown.render/1 still emits OSA's own styling" do
      out = Markdown.render("**bold** and `code`")
      assert String.contains?(out, IO.ANSI.bright()), "bold styling was lost"
      assert String.contains?(out, IO.ANSI.yellow()), "inline-code styling was lost"
      assert out =~ "bold"
      assert out =~ "code"
    end

    test "Renderer.print_response/2 emits no payload escape" do
      out = capture_io(fn -> Renderer.print_response(fixture_body()) end)
      refute_payload_survives(out, "Renderer.print_response/2")
    end

    test "Renderer.print_response/2 still prints the message and its gutter" do
      out = capture_io(fn -> Renderer.print_response("hello world") end)
      assert out =~ "hello world"
      assert out =~ "OSA"
    end

    test "Renderer.print_user_message/1 emits no payload escape" do
      out = capture_io(fn -> Renderer.print_user_message(fixture_body()) end)
      refute_payload_survives(out, "Renderer.print_user_message/1")
    end
  end

  describe "tool output on the plain-CLI path" do
    test "a rendered diff body cannot move the cursor" do
      out =
        capture_io(fn ->
          OptimalSystemAgent.Channels.CLI.DiffRenderer.print_indented(
            "#{@esc}[2J#{@esc}[9;30H+ approved\n- real change\n"
          )
        end)

      refute_payload_survives(out, "DiffRenderer.print_indented/2")
    end
  end
end
