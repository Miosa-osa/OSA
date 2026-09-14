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
  Compare the running version against the latest release this install can see.

  Returns `%{current, latest, update_available, status, source}` where `status`
  is one of:

    * `:update_available` — a strictly newer release is known.
    * `:current` — an authoritative source was consulted and says we are newest.
    * `:unknown` — **we could not find out.** No git tags, an unparseable
      version, or only the bundled changelog to go on.

  `:unknown` exists because it used to be indistinguishable from `:current`, and
  reporting the reassuring one is how this function told a user on a fresh
  install that they were up to date while a newer release sat on GitHub. Three
  separate defects fed that single lie:

    1. `Version.parse/1` rejects a leading zero in a component, and this
       project's tags are the padded display form (`v1.0.099`). Every compare
       involving one raised `:error`, which the old `else -> false` turned into
       "no update". Fixed by `normalize_semver/1`, which strips the padding.
    2. `git tag --sort=-v:refname` sorts `v1.0.4` ABOVE `v1.0.099`, so "the
       first tag git prints" was not the newest tag. We now take the maximum
       under our own comparison instead of trusting git's ordering.
    3. On a packaged install there are no git tags, so `latest` fell back to the
       BUNDLED changelog — a file that ships inside the release and therefore
       can never describe anything newer than the release you are already
       running. It cannot ever answer "yes", so it must not be allowed to answer
       "no" either. That case is now `:unknown`.

  Never performs a network install, and never performs network I/O at all.
  """
  @spec version_status() :: %{
          current: String.t(),
          latest: String.t(),
          update_available: boolean(),
          status: :update_available | :current | :unknown,
          source: :git_tags | :changelog | :none
        }
  def version_status do
    current = current_version()

    {source, latest} =
      case latest_release_tag() do
        nil -> {:changelog, latest_changelog_version()}
        tag -> {:git_tags, tag}
      end

    status = classify(source, latest, current)

    %{
      current: current,
      latest: latest || current,
      update_available: status == :update_available,
      status: status,
      source: if(latest, do: source, else: :none)
    }
  end

  # Git tags are authoritative for a checkout: the tag list really does name
  # every published release, so "nothing newer" is a fact we can assert.
  #
  # The bundled changelog is not. It travels inside the artifact, so the newest
  # entry it can possibly contain is the release running right now. Concluding
  # ":current" from it is circular — it would say "up to date" forever, on every
  # machine, no matter what had been published. It may only ever ESCALATE to
  # :update_available (a source checkout whose changelog is ahead of the built
  # version); otherwise the honest answer is that we did not check.
  defp classify(_source, nil, _current), do: :unknown

  defp classify(source, latest, current) do
    cond do
      not parseable?(latest) or not parseable?(current) -> :unknown
      version_newer?(latest, current) -> :update_available
      source == :git_tags -> :current
      true -> :unknown
    end
  end

  defp parseable?(v), do: match?({:ok, _}, parse_semver(v))

  # The newest semver git tag (e.g. "v0.4.6" -> "0.4.6"), or nil when git or the
  # tag list is unavailable.
  #
  # We deliberately do NOT ask git to order them. `--sort=-v:refname` puts
  # `v1.0.4` ahead of `v1.0.099` on this repo's real tag list, so taking git's
  # first line picked a two-year-old release as "latest" and every comparison
  # against it said "up to date". Sorting is ours to do, under the same
  # normalization every other compare here uses.
  defp latest_release_tag do
    if osa_source_checkout?() do
      case OptimalSystemAgent.Git.cmd(["tag", "--list", "v*"], stderr_to_stdout: true) do
        {out, 0} ->
          out
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&Regex.match?(~r/^v?\d+\.\d+\.\d+/, &1))
          |> Enum.map(&String.trim_leading(&1, "v"))
          |> Enum.filter(&parseable?/1)
          |> Enum.max_by(&parse_semver!/1, Version, fn -> nil end)

        _ ->
          nil
      end
    end
  rescue
    _ -> nil
  end

  # Git tags only name OSA's own releases when we are inside OSA's own source
  # checkout. Launched from another project's directory, `git tag` returns THAT
  # project's tags — a neighbour repo whose newest tag out-ranks OSA's running
  # version then masquerades as an OSA release and produces a phantom
  # "update available" (e.g. running OSA inside a CLI repo tagged v1.1.x). Only
  # trust the tag list when `origin` is the OSA repository; otherwise fall back
  # to the bundled changelog, which can only ever ESCALATE, so the honest answer
  # becomes "could not check" rather than a false update.
  @source_repo "miosa-osa/osa"
  defp osa_source_checkout? do
    case OptimalSystemAgent.Git.cmd(["remote", "get-url", "origin"], stderr_to_stdout: true) do
      {out, 0} -> owner_repo(out) == @source_repo
      _ -> false
    end
  rescue
    _ -> false
  end

  # "https://github.com/Miosa-osa/OSA.git" or "git@github.com:Miosa-osa/OSA.git"
  #   -> "miosa-osa/osa"  (owner/repo, case-folded, ".git" stripped)
  defp owner_repo(remote_url) do
    remote_url
    |> String.trim()
    |> String.downcase()
    |> String.replace_suffix(".git", "")
    |> String.split(~r{[/:]}, trim: true)
    |> Enum.take(-2)
    |> Enum.join("/")
  end

  defp parse_semver!(v) do
    {:ok, parsed} = parse_semver(v)
    parsed
  end

  defp latest_changelog_version do
    entries()
    |> Enum.map(& &1.version)
    |> Enum.find(fn v -> Regex.match?(~r/^\d+\.\d+\.\d+/, v) end)
  end

  # true when `a` is a strictly-newer semver than `b`. Non-semver -> false.
  # Callers that need to tell "older" from "cannot tell" must check
  # `version_status/0`'s `:status`, not this predicate.
  @doc false
  def version_newer?(a, b) do
    with {:ok, va} <- parse_semver(a),
         {:ok, vb} <- parse_semver(b) do
      Version.compare(va, vb) == :gt
    else
      _ -> false
    end
  end

  @doc """
  Parse a version string that may be in this project's PADDED display form.

  Tags and changelog headings are written `v1.0.099` so they sort readably for a
  human, but semver forbids leading zeros and `Version.parse("1.0.099")` returns
  `:error`. Strip the padding per numeric component so the padded tag, the
  normalized build stamp (`1.0.99`) and `1.0.100` all compare correctly against
  one another.
  """
  @spec normalize_semver(String.t()) :: String.t()
  def normalize_semver(v) when is_binary(v) do
    {core, suffix} =
      case Regex.run(~r/^([^-+]*)(.*)$/, String.trim(v) |> String.trim_leading("v")) do
        [_, c, s] -> {c, s}
        _ -> {v, ""}
      end

    core
    |> String.split(".")
    |> Enum.map(fn part ->
      if part != "" and String.match?(part, ~r/^\d+$/) do
        Integer.to_string(String.to_integer(part))
      else
        part
      end
    end)
    |> Enum.join(".")
    |> Kernel.<>(suffix)
  end

  def normalize_semver(v), do: to_string(v)

  defp parse_semver(v) when is_binary(v) do
    case Regex.run(~r/^v?(\d+\.\d+\.\d+)/, String.trim(v)) do
      [_, core] -> Version.parse(normalize_semver(core))
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
