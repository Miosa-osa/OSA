defmodule OptimalSystemAgent.CLI do
  @moduledoc """
  Entry point for the `osagent` release binary.

  Dispatches subcommands:
    osagent           interactive chat (default)
    osagent setup     configure provider, API keys
    osagent version   print version
    osagent serve     headless HTTP API mode
    osagent doctor    system health check
    osagent update    pull latest code, recompile, restart
  """

  @app :optimal_system_agent

  def chat do
    # Silence boot logs for clean CLI startup
    Logger.configure(level: :none)

    {:ok, _} = Application.ensure_all_started(@app)

    Logger.configure(level: :warning)

    migrate!()

    # Seed workspace templates on first run
    OptimalSystemAgent.Onboarding.seed_workspace()

    OptimalSystemAgent.Channels.CLI.start()
  end

  def setup do
    {:ok, _} = Application.ensure_all_started(:jason)
    IO.puts("Run the TUI and type /setup to configure. Or edit ~/.osa/.env directly.")
  end

  def version do
    Application.load(@app)
    vsn = Application.spec(@app, :vsn) |> to_string()
    safe_puts("osagent v#{vsn}")
  end

  def serve do
    {:ok, _} = Application.ensure_all_started(@app)
    migrate!()
    OptimalSystemAgent.Onboarding.seed_workspace()

    port = Application.get_env(@app, :http_port, 9089)
    safe_puts("OSA serving on :#{port}")
    Process.sleep(:infinity)
  end

  def doctor do
    OptimalSystemAgent.CLI.Doctor.run()
  end

  def update do
    safe_puts("Updating OSA Agent...")

    # Find project root
    root =
      case File.read(Path.join([System.user_home!(), ".osa", "project_root"])) do
        {:ok, path} -> String.trim(path)
        _ ->
          # Fallback: walk up from priv dir
          :code.priv_dir(@app) |> to_string() |> Path.join("..") |> Path.expand()
      end

    if not File.exists?(Path.join(root, "mix.exs")) do
      safe_puts("Error: Cannot find project at #{root}")
      System.halt(1)
    end

    safe_puts("  Project: #{root}")

    # Git pull
    safe_puts("  Pulling latest...")
    case System.cmd("git", ["pull", "--ff-only", "origin", "main"], cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        safe_puts("  #{String.trim(output)}")

      {output, _} ->
        safe_puts("  Warning: git pull failed: #{String.trim(output)}")
        safe_puts("  Continuing with recompile...")
    end

    # Deps + compile
    safe_puts("  Fetching dependencies...")
    System.cmd("mix", ["deps.get"], cd: root, stderr_to_stdout: true)

    safe_puts("  Compiling...")
    case System.cmd("mix", ["compile"], cd: root, stderr_to_stdout: true) do
      {_, 0} -> safe_puts("  ✓ Compiled successfully")
      {output, _} -> safe_puts("  Warning: #{String.trim(output)}")
    end

    # Rebuild Rust TUI if it exists
    tui_dir = Path.join([root, "priv", "rust", "tui"])
    if File.exists?(Path.join(tui_dir, "Cargo.toml")) do
      safe_puts("  Rebuilding TUI...")
      case System.cmd("cargo", ["build", "--release"], cd: tui_dir, stderr_to_stdout: true) do
        {_, 0} -> safe_puts("  ✓ TUI rebuilt")
        {output, _} -> safe_puts("  Warning: TUI build: #{String.trim(output)}")
      end
    end

    safe_puts("")
    safe_puts("✓ Update complete. Restart OSA to use the new version.")
  end

  # ── Migrations ──────────────────────────────────────────────────

  defp migrate! do
    priv = :code.priv_dir(@app) |> to_string()
    migrations_path = Path.join([priv, "repo", "migrations"])

    if File.dir?(migrations_path) do
      Ecto.Migrator.run(
        OptimalSystemAgent.Store.Repo,
        migrations_path,
        :up,
        all: true,
        log: false
      )
    end
  end

  # On Windows a backgrounded process loses its console HANDLE; any IO call
  # into prim_tty returns {:error, :enotsup} or raises ErlangError wrapping
  # :eio.  This helper swallows those errors so the serve/version commands
  # do not crash the VM when stdout is unavailable.
  defp safe_puts(msg) do
    IO.puts(msg)
  rescue
    ErlangError -> :ok
  catch
    :error, :enotsup -> :ok
    :error, :eio     -> :ok
  end
end
