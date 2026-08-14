defmodule OptimalSystemAgent.Channels.CLI.Renderer do
  @moduledoc """
  Output formatting, colors, display, and terminal helpers for the CLI REPL.

  Handles the banner, response printing, status line, text wrapping,
  separators, and terminal geometry queries.
  """

  alias OptimalSystemAgent.CLI.Sanitize
  alias OptimalSystemAgent.Channels.CLI.Markdown

  @reset IO.ANSI.reset()
  @bold IO.ANSI.bright()
  @dim IO.ANSI.faint()
  @cyan IO.ANSI.cyan()
  @yellow IO.ANSI.yellow()
  @white IO.ANSI.white()
  @green IO.ANSI.green()

  # ── Banner ──────────────────────────────────────────────────────────

  def print_banner do
    # ── Gather live data ──────────────────────────────────────────────
    provider = Application.get_env(:optimal_system_agent, :default_provider, :unknown)
    model = get_model_name(provider)
    version = Application.spec(:optimal_system_agent, :vsn) |> to_string()
    git_hash = git_short_hash()
    cwd = prompt_dir()
    width = min(terminal_width(), 80)

    # Tools the MODEL actually receives, not everything registered.
    #
    # This counted `list_tools_direct/0`, the full registry — 81 on this
    # install — while the model is sent `list_active/0`, which is 37. The banner
    # was reporting more than double the tools the agent can actually call.
    tool_count =
      try do
        length(OptimalSystemAgent.Tools.Registry.list_active())
      rescue
        _ -> 0
      end

    # The model's REAL context window, asked of the registry.
    #
    # This read `:max_context_tokens` from config, whose default is 128_000 —
    # a static number with no relationship to the model in use. A 1M-window
    # model (`glm-5.2:cloud`) printed "128K context" on every launch. Same
    # defect as the small-window gate fixed in v1.0.84: a surface stating a
    # fabricated number instead of asking the one function that knows.
    ctx_window =
      try do
        OptimalSystemAgent.Providers.Registry.effective_context_window(model, provider) ||
          Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
      rescue
        _ -> Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
      end

    ctx_display =
      if ctx_window >= 1_000_000,
        do: "#{div(ctx_window, 1_000_000)}M context",
        else: "#{div(ctx_window, 1_000)}K context"

    # Connected channels
    channels =
      try do
        OptimalSystemAgent.Channels.Manager.list_channels()
        |> Enum.filter(& &1.connected)
        |> Enum.map(& &1.name)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    channels_str = if channels == [], do: "none", else: Enum.join(channels, ", ")

    # Auth mode. Always "api key" — the Anthropic subscription sign-in that
    # used to make this read "oauth" was removed (see
    # `OptimalSystemAgent.Auth.LegacyAnthropicOAuth`).
    auth_status = "api key"

    # Soul/identity status
    soul_status =
      try do
        if OptimalSystemAgent.Soul.identity(), do: "custom", else: "default"
      rescue
        _ -> "default"
      end

    # Recent session count
    session_count =
      try do
        Registry.select(OptimalSystemAgent.SessionRegistry, [{{:_, :_, :_}, [], [true]}])
        |> length()
      rescue
        _ -> 0
      catch
        :exit, _ -> 0
      end

    scheduler_str = scheduler_status()

    # ── Build bordered box ────────────────────────────────────────────
    inner_width = width - 4
    title = " #{@bold}#{@cyan}OSA#{@reset} #{@dim}v#{version} (#{git_hash})#{@reset} "
    title_visible = "OSA v#{version} (#{git_hash})"

    top_border =
      "#{@dim}╭─#{@reset}#{title}#{@dim}#{String.duplicate("─", max(inner_width - String.length(title_visible) - 3, 0))}╮#{@reset}"

    # ASCII art logo
    logo = [
      "#{@cyan} ██████╗ ███████╗ █████╗#{@reset}",
      "#{@cyan}██╔═══██╗██╔════╝██╔══██╗#{@reset}",
      "#{@cyan}██║   ██║███████╗███████║#{@reset}",
      "#{@cyan}██║   ██║╚════██║██╔══██║#{@reset}",
      "#{@cyan}╚██████╔╝███████║██║  ██║#{@reset}",
      "#{@cyan} ╚═════╝ ╚══════╝╚═╝  ╚═╝#{@reset}"
    ]

    # Left panel — logo + system status
    left_lines =
      logo ++
        [
          "",
          "#{@cyan}#{provider}#{@reset}#{@dim} / #{model}#{@reset}",
          "#{@dim}#{ctx_display} · #{tool_count} tools#{@reset}",
          "#{@dim}auth: #{auth_status} · soul: #{soul_status}#{@reset}",
          "#{@dim}scheduler: #{scheduler_str}#{@reset}",
          "#{@dim}#{cwd}#{@reset}"
        ]

    # Right panel — live info
    right_lines = [
      "#{@yellow}Ready#{@reset}",
      "#{@dim}Ask, code, schedule, delegate#{@reset}",
      "#{@dim}/help — commands#{@reset}",
      "#{@dim}/model — switch model#{@reset}",
      "#{@dim}/setup — reconfigure#{@reset}",
      "#{@dim}#{String.duplicate("─", 28)}#{@reset}",
      "#{@yellow}System#{@reset}",
      "#{@dim}channels: #{channels_str}#{@reset}",
      if(session_count > 0,
        do: "#{@dim}sessions: #{session_count} active#{@reset}",
        else: "#{@dim}sessions: new#{@reset}"
      ),
      "#{@dim}#{String.duplicate("─", 28)}#{@reset}",
      "#{@dim}Ctrl+C cancel · Ctrl+J newline#{@reset}"
    ]

    # Render
    IO.puts("")
    IO.puts("  #{top_border}")

    max_lines = max(length(left_lines), length(right_lines))
    left_width = div(inner_width, 2)
    right_width = inner_width - left_width - 1

    for i <- 0..(max_lines - 1) do
      left = Enum.at(left_lines, i, "")
      right = Enum.at(right_lines, i, "")
      left_padded = pad_visible(left, left_width)
      right_padded = pad_visible(right, right_width)
      sep = if right != "", do: "#{@dim}│#{@reset}", else: " "
      IO.puts("  #{@dim}│#{@reset} #{left_padded}#{sep}#{right_padded} #{@dim}│#{@reset}")
    end

    IO.puts("  #{@dim}╰#{String.duplicate("─", inner_width + 2)}╯#{@reset}")
    IO.puts("")
  end

  defp pad_visible(str, width) do
    vis_len = visible_length(str)
    padding = max(width - vis_len, 0)
    str <> String.duplicate(" ", padding)
  end

  defp scheduler_status do
    case OptimalSystemAgent.Agent.Scheduler.status() do
      %{cron_active: active, cron_total: total, heartbeat_pending: pending} ->
        "#{active}/#{total} active · #{pending} heartbeat"

      _ ->
        "ready"
    end
  rescue
    _ -> "starting"
  catch
    :exit, _ -> "starting"
  end

  def print_goodbye do
    IO.puts("\n#{@dim}  goodbye#{@reset}\n")
  end

  def print_separator do
    width = terminal_width()
    IO.puts("#{@dim}  #{String.duplicate("─", width - 4)}#{@reset}")
  end

  # ── User Message ────────────────────────────────────────────────────

  def print_user_message(text) do
    # Show user's message with a header, like a chat bubble
    IO.puts("")
    IO.puts("#{@bold}#{@cyan}  ❯  You#{@reset}")

    text
    |> Sanitize.scrub_block()
    |> String.split("\n")
    |> Enum.each(fn line ->
      IO.puts("#{@dim}  │  #{@reset}#{@white}#{Sanitize.scrub_line(line)}#{@reset}")
    end)

    IO.puts("")
  end

  # ── Response Formatting ─────────────────────────────────────────────

  def print_response(response, opts \\ []) do
    unless opts[:already_streamed] do
      rendered = Markdown.render(response)
      width = terminal_width()
      lines = wrap_text(rendered, width - 6)

      IO.puts("")
      IO.puts("#{@bold}#{@cyan}  ◇  OSA#{@reset}")

      Enum.each(lines, fn line ->
        IO.puts("#{@dim}  │  #{@reset}#{@white}#{line}#{@reset}")
      end)

      IO.puts("")
    end
  end

  # ── Status Line ─────────────────────────────────────────────────────

  def show_status_line(elapsed_ms, tool_count, total_tokens, cost_usd \\ nil) do
    parts = ["#{@green}✓#{@dim} " <> format_elapsed(elapsed_ms)]
    parts = if tool_count > 0, do: parts ++ ["#{tool_count} tools"], else: parts
    parts = if total_tokens > 0, do: parts ++ [format_tokens(total_tokens)], else: parts

    parts =
      if is_number(cost_usd) and cost_usd > 0 do
        parts ++ ["$#{:erlang.float_to_binary(cost_usd * 1.0, decimals: 4)}"]
      else
        parts
      end

    parts =
      try do
        case :ets.lookup(:cli_signal_cache, :context_pressure) do
          [{:context_pressure, util}] when util >= 50.0 ->
            label =
              cond do
                util >= 95.0 -> "#{IO.ANSI.red()}ctx #{Float.round(util, 0)}%#{@dim}"
                util >= 85.0 -> "#{IO.ANSI.red()}ctx #{Float.round(util, 0)}%#{@dim}"
                util >= 70.0 -> "#{@yellow}ctx #{Float.round(util, 0)}%#{@dim}"
                true -> "ctx #{Float.round(util, 0)}%"
              end

            parts ++ [label]

          _ ->
            parts
        end
      rescue
        _ -> parts
      end

    IO.puts("#{@dim}  #{Enum.join(parts, " · ")}#{@reset}")
  end

  # ── Event Display ───────────────────────────────────────────────────

  def context_pressure_bar(util) when util >= 95.0, do: "█████ CRITICAL"
  def context_pressure_bar(util) when util >= 90.0, do: "████░ HIGH"
  def context_pressure_bar(util) when util >= 85.0, do: "███░░ ELEVATED"
  def context_pressure_bar(util) when util >= 70.0, do: "██░░░ WARM"
  def context_pressure_bar(_util), do: "█░░░░"

  # ── Time / Token Formatters (delegates to shared Format module) ──────

  defdelegate format_elapsed(ms), to: OptimalSystemAgent.Channels.CLI.Format

  defdelegate format_tokens(n),
    to: OptimalSystemAgent.Channels.CLI.Format,
    as: :format_tokens_arrow

  def format_duration_ms(nil), do: ""
  def format_duration_ms(ms) when is_number(ms), do: format_elapsed(ms)
  def format_duration_ms(_), do: ""

  # ── Terminal Helpers ────────────────────────────────────────────────

  defdelegate terminal_width(), to: OptimalSystemAgent.Channels.CLI.Format

  def clear_line do
    width = terminal_width()
    IO.write("\r#{String.duplicate(" ", width)}\r")
  end

  # ── Text Wrapping ───────────────────────────────────────────────────

  defdelegate wrap_text(text, width), to: OptimalSystemAgent.CLI.Width, as: :wrap

  # Display width in terminal COLUMNS. This was `String.length/1` over an
  # SGR-only strip, which counted a CJK/emoji grapheme as one column (tearing the
  # box border) and counted cursor-movement CSI and OSC-8 hyperlinks as visible.
  defp visible_length(str), do: OptimalSystemAgent.CLI.Width.visible(str)

  # ── Directory Display ──────────────────────────────────────────────

  def prompt_dir do
    cwd = File.cwd!()
    home = System.get_env("HOME") || ""

    shortened =
      if home != "" and String.starts_with?(cwd, home) do
        "~" <> String.trim_leading(cwd, home)
      else
        cwd
      end

    parts = Path.split(shortened)

    case length(parts) do
      n when n > 3 -> "~/…/" <> List.last(parts)
      _ -> shortened
    end
  rescue
    _ -> "."
  end

  # ── Private Helpers ─────────────────────────────────────────────────

  defp git_short_hash do
    case OptimalSystemAgent.Git.cmd(["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {hash, 0} -> String.trim(hash)
      _ -> "dev"
    end
  rescue
    _ -> "dev"
  end

  defp get_model_name(provider) do
    OptimalSystemAgent.Channels.CLI.Format.get_model_name(provider)
  end
end
