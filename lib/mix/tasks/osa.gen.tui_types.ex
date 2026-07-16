defmodule Mix.Tasks.Osa.Gen.TuiTypes do
  @shortdoc "Generate the Rust TUI client types from the Elixir protocol schema"

  @moduledoc """
  Project the Elixir protocol (`OptimalSystemAgent.Protocol.TUISchema`) into the
  Rust TUI client's generated serde structs.

      mix osa.gen.tui_types            # (re)write priv/rust/tui/src/client/generated.rs
      mix osa.gen.tui_types --check    # exit 1 if generated.rs is out of date

  The `--check` form is CI-friendly: it never writes, it only verifies that the
  committed `generated.rs` matches what the current schema would produce, so the
  Rust client can never silently drift from the Elixir HTTP API.
  """

  use Mix.Task

  alias OptimalSystemAgent.Protocol.TUISchema

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [check: :boolean])

    path = TUISchema.output_path()
    rel = TUISchema.relative_output_path()
    rendered = TUISchema.render()

    if opts[:check] do
      check(path, rel, rendered)
    else
      write(path, rel, rendered)
    end
  end

  defp check(path, rel, rendered) do
    case File.read(path) do
      {:ok, ^rendered} ->
        Mix.shell().info("#{rel} is up to date (#{length(TUISchema.type_names())} types).")

      {:ok, _stale} ->
        Mix.raise(
          "#{rel} is OUT OF DATE.\n" <>
            "Run `mix osa.gen.tui_types` and commit the result."
        )

      {:error, :enoent} ->
        Mix.raise("#{rel} is missing. Run `mix osa.gen.tui_types`.")

      {:error, reason} ->
        Mix.raise("Could not read #{rel}: #{inspect(reason)}")
    end
  end

  defp write(path, rel, rendered) do
    File.mkdir_p!(Path.dirname(path))

    changed? =
      case File.read(path) do
        {:ok, ^rendered} -> false
        _ -> true
      end

    File.write!(path, rendered)

    if changed? do
      Mix.shell().info("Generated #{rel} (#{length(TUISchema.type_names())} types).")
    else
      Mix.shell().info("#{rel} already up to date (#{length(TUISchema.type_names())} types).")
    end
  end
end
