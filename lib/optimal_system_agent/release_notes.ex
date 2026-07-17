defmodule OptimalSystemAgent.ReleaseNotes do
  @moduledoc """
  Release-notes / CHANGELOG resource + version-check backend.

  Backs three surfaces:

    * `osa update` launcher — prints `latest_text/0` after pulling.
    * `/release-notes` slash command — `cmd_release_notes` in the CLI commands.
    * `GET /api/v1/release-notes` + `GET /api/v1/version` HTTP endpoints.

  The changelog is a bundled Keep-a-Changelog file (`priv/CHANGELOG.md`, with a
  repo-root/`docs/` fallback for source checkouts). Version-check compares the
  running version against the newest release tag (git, falling back to the
  newest changelog entry) — it never auto-installs.
  """

  @app :optimal_system_agent

  # ── Version ──────────────────────────────────────────────────────────

  @doc """
  The running OSA version — single source of truth for every reporter.

  Resolution order (first hit wins):

    1. `OSA_VERSION` env — the stamp the release CI injects into the built
       artifact so a tagged build always reports its exact tag.
    2. The compiled app spec `:vsn` (derived from the `VERSION` file at build
       time via `mix.exs`).
    3. The `VERSION` file on disk (source checkouts).
    4. `"unknown"`.
  """
  @spec current_version() :: String.t()
  def current_version do
    case System.get_env("OSA_VERSION") do
      v when is_binary(v) and v != "" ->
        String.trim(v)

      _ ->
        case Application.spec(@app, :vsn) do
          nil -> read_version_file()
          vsn -> to_string(vsn)
        end
    end
  end

  defp read_version_file do
    [Path.expand("VERSION"), version_file_in_priv()]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value("unknown", fn path ->
      case File.read(path) do
        {:ok, v} -> String.trim(v)
        _ -> nil
      end
    end)
  end

  defp version_file_in_priv do
    case :code.priv_dir(@app) do
      {:error, _} -> nil
      dir -> Path.join([to_string(dir), "..", "VERSION"]) |> Path.expand()
    end
  end

  @doc """
  Compare the running version against the latest known release tag.

  Returns `%{current, latest, update_available}`. `latest` comes from git tags
  when available (a source checkout), otherwise the newest changelog entry with
  a real version number. Never performs a network install.
  """
  @spec version_status() :: %{
          current: String.t(),
          latest: String.t(),
          update_available: boolean()
        }
  def version_status do
    current = current_version()
    latest = latest_release_tag() || latest_changelog_version() || current

    %{
      current: current,
      latest: latest,
      update_available: version_newer?(latest, current)
    }
  end

  # Newest semver git tag (e.g. "v0.4.6" -> "0.4.6"). nil when git/tags absent.
  defp latest_release_tag do
    case System.cmd("git", ["tag", "--list", "v*", "--sort=-v:refname"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.find_value(fn tag ->
          case Regex.run(~r/^v?(\d+\.\d+\.\d+.*)$/, tag) do
            [_, v] -> v
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp latest_changelog_version do
    entries()
    |> Enum.map(& &1.version)
    |> Enum.find(fn v -> Regex.match?(~r/^\d+\.\d+\.\d+/, v) end)
  end

  # true when `a` is a strictly-newer semver than `b`. Non-semver -> false.
  @doc false
  def version_newer?(a, b) do
    with {:ok, va} <- parse_semver(a),
         {:ok, vb} <- parse_semver(b) do
      Version.compare(va, vb) == :gt
    else
      _ -> false
    end
  end

  defp parse_semver(v) when is_binary(v) do
    case Regex.run(~r/^v?(\d+\.\d+\.\d+)/, String.trim(v)) do
      [_, core] -> Version.parse(core)
      _ -> :error
    end
  end

  defp parse_semver(_), do: :error

  # ── Changelog resource ───────────────────────────────────────────────

  @doc "Absolute path to the changelog resource, or nil if none is bundled."
  @spec changelog_path() :: String.t() | nil
  def changelog_path do
    candidates()
    |> Enum.find(&File.regular?/1)
  end

  defp candidates do
    priv =
      case :code.priv_dir(@app) do
        {:error, _} -> if File.dir?("priv"), do: Path.expand("priv"), else: nil
        dir -> to_string(dir)
      end

    [
      priv && Path.join(priv, "CHANGELOG.md"),
      Path.expand("priv/CHANGELOG.md"),
      Path.expand("CHANGELOG.md"),
      Path.expand("docs/operations/changelog.md")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Parse the changelog into `[%{version, date, body}]`, newest first.

  Each entry is one `## [version] - date` section of a Keep-a-Changelog file.
  Returns `[]` when no changelog resource is present.
  """
  @spec entries() :: [%{version: String.t(), date: String.t() | nil, body: String.t()}]
  def entries do
    case changelog_path() do
      nil ->
        []

      path ->
        case File.read(path) do
          {:ok, content} -> parse_entries(content)
          _ -> []
        end
    end
  end

  @doc "The single newest changelog entry, or nil when the changelog is empty."
  @spec latest() :: %{version: String.t(), date: String.t() | nil, body: String.t()} | nil
  def latest, do: entries() |> List.first()

  @doc """
  Human-readable text for the newest `n` entries (default 1).

  Used by the `osa update` launcher and the `/release-notes` command. Falls back
  to a friendly line when no changelog is bundled.
  """
  @spec latest_text(pos_integer()) :: String.t()
  def latest_text(n \\ 1) do
    case Enum.take(entries(), n) do
      [] ->
        "No release notes bundled (OSA v#{current_version()})."

      list ->
        list
        |> Enum.map(fn e ->
          header = "## #{e.version}" <> if(e.date, do: " — #{e.date}", else: "")
          header <> "\n\n" <> e.body
        end)
        |> Enum.join("\n\n")
        |> String.trim()
    end
  end

  # Split on "## [ver] - date" headers (the "[Unreleased]" section included).
  defp parse_entries(content) do
    header_re = ~r/^\#\#\s+\[([^\]]+)\](?:\s*[-–]\s*(.+))?\s*$/m

    content
    |> split_sections(header_re)
    |> Enum.map(fn {version, date, body} ->
      %{version: version, date: date && String.trim(date), body: String.trim(body)}
    end)
  end

  # Walk the file line-by-line, opening a new section at each version header.
  defp split_sections(content, header_re) do
    lines = String.split(content, "\n")

    {sections, current} =
      Enum.reduce(lines, {[], nil}, fn line, {acc, cur} ->
        case Regex.run(header_re, line) do
          [_, version | rest] ->
            date = List.first(rest)
            new_cur = {version, date, []}
            acc = if cur, do: [finalize(cur) | acc], else: acc
            {acc, new_cur}

          nil ->
            case cur do
              {v, d, body_lines} -> {acc, {v, d, [line | body_lines]}}
              nil -> {acc, nil}
            end
        end
      end)

    sections = if current, do: [finalize(current) | sections], else: sections
    Enum.reverse(sections)
  end

  defp finalize({version, date, body_lines}) do
    {version, date, body_lines |> Enum.reverse() |> Enum.join("\n")}
  end
end
