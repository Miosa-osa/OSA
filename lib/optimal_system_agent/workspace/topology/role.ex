defmodule OptimalSystemAgent.Workspace.Topology.Role do
  @moduledoc """
  Evidence-based role inference for a single component directory.

  ## The rule: never invent a role

  The operator-facing map has a "Role" column, and **a fabricated role is worse
  than a blank one**. Every value this module returns is derived from a file
  that actually exists on disk (a manifest, an entrypoint, a chart). When the
  evidence does not decide, we return `:unknown` and the renderer prints `—`.

  Three orthogonal facts are inferred, each independently allowed to be nil:

    * `language`  — from the manifest filename (`mix.exs` → Elixir, `go.mod` → Go…)
    * `framework` — from *declared dependencies* inside that manifest, never from
      directory names
    * `role`      — `:app | :library | :sdk | :infra | :docs | :tests | :unknown`,
      from entrypoint evidence (a `mod:` in an Elixir application callback, a
      `cmd/` dir next to a `go.mod`, `src/main.rs`, a `start` script…)

  All parsing is deliberately shallow — regex over a size-capped read, no JSON
  schema validation, no `Code.eval`. A component manifest is attacker-authored
  content; we extract signals from it, we never execute it.
  """

  # Manifests are read only far enough to spot dependency/entrypoint markers.
  # Nothing downstream needs the tail of a 4 MB lockfile-ish package.json.
  @read_cap 64_000

  @type language :: String.t() | nil
  @type role :: :app | :library | :sdk | :infra | :docs | :tests | :unknown

  @type info :: %{
          language: language(),
          framework: String.t() | nil,
          role: role(),
          name: String.t(),
          evidence: [String.t()]
        }

  # Manifest filename → language. Order matters: the first manifest found in a
  # directory decides the primary language, so compiled-app manifests are
  # listed ahead of ancillary ones.
  @manifests [
    {"mix.exs", "Elixir"},
    {"Cargo.toml", "Rust"},
    {"go.mod", "Go"},
    {"package.json", "JavaScript"},
    {"pyproject.toml", "Python"},
    {"setup.py", "Python"},
    {"requirements.txt", "Python"},
    {"pom.xml", "Java"},
    {"build.gradle", "Java"},
    {"build.gradle.kts", "Kotlin"},
    {"Gemfile", "Ruby"},
    {"composer.json", "PHP"},
    {"Package.swift", "Swift"},
    {"pubspec.yaml", "Dart"},
    {"CMakeLists.txt", "C/C++"},
    {"*.csproj", ".NET"}
  ]

  @doc "Manifest filenames that mark a directory as a real component."
  @spec manifest_names() :: [String.t()]
  def manifest_names, do: Enum.map(@manifests, &elem(&1, 0))

  @doc """
  The first manifest present in `dir`, as `{filename, language}`, or `nil`.
  """
  @spec primary_manifest(String.t()) :: {String.t(), String.t()} | nil
  def primary_manifest(dir) do
    Enum.find_value(@manifests, fn
      {"*." <> ext, lang} ->
        case Path.wildcard(Path.join(dir, "*." <> ext)) do
          [first | _] -> {Path.basename(first), lang}
          [] -> nil
        end

      {name, lang} ->
        if File.regular?(Path.join(dir, name)), do: {name, lang}
    end)
  end

  @doc """
  Infer language, framework, role and display name for `dir`.

  `hint` carries structural knowledge the caller already has and this module
  cannot see from one directory alone — e.g. `:sdk` because the directory sits
  under `sdks/`, or `:infra` because the parent declared a Terraform tree. A
  hint only ever *breaks a tie*: hard on-disk evidence (a Helm `Chart.yaml`, a
  `main.rs`) still wins over it.
  """
  @spec infer(String.t(), atom() | nil) :: info()
  def infer(dir, hint \\ nil) do
    manifest = primary_manifest(dir)
    infra = infra_evidence(dir)
    entries = safe_ls(dir)

    {language, framework, declared_name, manifest_ev} = from_manifest(dir, manifest)

    evidence =
      Enum.reject(
        [manifest && elem(manifest, 0), infra && elem(infra, 1)] ++ manifest_ev,
        &is_nil/1
      )

    role =
      cond do
        # Hard infra evidence beats everything: a directory with a Helm chart or
        # a Terraform root IS infra regardless of what else it contains.
        infra != nil -> :infra
        docs_only?(dir, entries, manifest) -> :docs
        tests_only?(dir, entries, manifest) -> :tests
        sdk?(dir, declared_name, hint) -> :sdk
        manifest != nil -> app_or_library(dir, manifest, entries)
        hint in [:app, :library, :sdk, :infra, :docs] -> hint
        true -> :unknown
      end

    language =
      cond do
        language != nil -> language
        infra != nil -> elem(infra, 0)
        true -> nil
      end

    %{
      language: language,
      framework: framework,
      role: role,
      name: declared_name || Path.basename(Path.expand(dir)),
      evidence: Enum.uniq(evidence)
    }
  rescue
    _ ->
      %{
        language: nil,
        framework: nil,
        role: :unknown,
        name: Path.basename(Path.expand(dir)),
        evidence: []
      }
  end

  @doc "Human label for a role. `:unknown` renders as an em dash, never a guess."
  @spec role_label(role()) :: String.t()
  def role_label(:app), do: "app"
  def role_label(:library), do: "library"
  def role_label(:sdk), do: "SDK"
  def role_label(:infra), do: "infra"
  def role_label(:docs), do: "docs"
  def role_label(:tests), do: "tests"
  def role_label(_), do: "unknown"

  # ── Manifest parsing ──────────────────────────────────────────────────

  defp from_manifest(_dir, nil), do: {nil, nil, nil, []}

  defp from_manifest(dir, {file, lang}) do
    body = read_capped(Path.join(dir, file))
    {framework, name} = parse(file, body, dir)
    {lang, framework, name, []}
  end

  defp parse("mix.exs", body, _dir) do
    name =
      case Regex.run(~r/def\s+project\s+do.{0,600}?app:\s*:([a-z0-9_]+)/s, body) do
        [_, app] -> app
        _ -> nil
      end

    framework =
      cond do
        Regex.match?(~r/:phoenix_live_view\s*,/, body) -> "Phoenix LiveView"
        Regex.match?(~r/\{\s*:phoenix\s*,/, body) -> "Phoenix"
        Regex.match?(~r/\{\s*:nerves\s*,/, body) -> "Nerves"
        Regex.match?(~r/\{\s*:ecto(_sql)?\s*,/, body) -> "Ecto"
        true -> nil
      end

    {framework, name}
  end

  defp parse("package.json", body, _dir) do
    name =
      case Regex.run(~r/"name"\s*:\s*"([^"]+)"/, body) do
        [_, n] -> n
        _ -> nil
      end

    framework =
      cond do
        Regex.match?(~r/"(next)"\s*:/, body) -> "Next.js"
        Regex.match?(~r/"(@sveltejs\/kit)"\s*:/, body) -> "SvelteKit"
        Regex.match?(~r/"(svelte)"\s*:/, body) -> "Svelte"
        Regex.match?(~r/"(nuxt)"\s*:/, body) -> "Nuxt"
        Regex.match?(~r/"(@nestjs\/core)"\s*:/, body) -> "NestJS"
        Regex.match?(~r/"(react)"\s*:/, body) -> "React"
        Regex.match?(~r/"(fastify)"\s*:/, body) -> "Fastify"
        Regex.match?(~r/"(express)"\s*:/, body) -> "Express"
        Regex.match?(~r/"(vite)"\s*:/, body) -> "Vite"
        true -> nil
      end

    {framework, name}
  end

  defp parse("Cargo.toml", body, _dir) do
    name =
      case Regex.run(~r/\[package\][^\[]*?\bname\s*=\s*"([^"]+)"/s, body) do
        [_, n] -> n
        _ -> nil
      end

    framework =
      cond do
        Regex.match?(~r/^\s*axum\s*=/m, body) -> "Axum"
        Regex.match?(~r/^\s*actix-web\s*=/m, body) -> "Actix"
        Regex.match?(~r/^\s*ratatui\s*=/m, body) -> "ratatui"
        Regex.match?(~r/^\s*tokio\s*=/m, body) -> "Tokio"
        true -> nil
      end

    {framework, name}
  end

  defp parse("go.mod", body, _dir) do
    name =
      case Regex.run(~r/^\s*module\s+(\S+)/m, body) do
        [_, m] -> m
        _ -> nil
      end

    framework =
      cond do
        String.contains?(body, "github.com/gin-gonic/gin") -> "Gin"
        String.contains?(body, "github.com/go-chi/chi") -> "Chi"
        String.contains?(body, "github.com/labstack/echo") -> "Echo"
        true -> nil
      end

    {framework, name}
  end

  defp parse("pyproject.toml", body, _dir) do
    name =
      case Regex.run(~r/^\s*name\s*=\s*"([^"]+)"/m, body) do
        [_, n] -> n
        _ -> nil
      end

    framework =
      cond do
        Regex.match?(~r/\bfastapi\b/i, body) -> "FastAPI"
        Regex.match?(~r/\bdjango\b/i, body) -> "Django"
        Regex.match?(~r/\bflask\b/i, body) -> "Flask"
        true -> nil
      end

    {framework, name}
  end

  defp parse(_file, _body, _dir), do: {nil, nil}

  # ── Role decision ─────────────────────────────────────────────────────

  # `:app` requires a *runnable* entrypoint; anything else with a manifest is a
  # library. There is no third guess here — if neither matches we still return
  # :library, because "has a package manifest but no entrypoint" is exactly what
  # a library is.
  defp app_or_library(dir, {"mix.exs", _}, _entries) do
    body = read_capped(Path.join(dir, "mix.exs"))

    cond do
      Regex.match?(~r/mod:\s*\{/, body) -> :app
      File.dir?(Path.join(dir, "apps")) -> :app
      true -> :library
    end
  end

  defp app_or_library(dir, {"go.mod", _}, _entries) do
    cond do
      File.dir?(Path.join(dir, "cmd")) -> :app
      File.regular?(Path.join(dir, "main.go")) -> :app
      true -> :library
    end
  end

  defp app_or_library(dir, {"Cargo.toml", _}, _entries) do
    cond do
      File.regular?(Path.join(dir, "src/main.rs")) -> :app
      File.regular?(Path.join(dir, "src/lib.rs")) -> :library
      true -> :library
    end
  end

  defp app_or_library(dir, {"package.json", _}, _entries) do
    body = read_capped(Path.join(dir, "package.json"))

    cond do
      Regex.match?(~r/"scripts"\s*:\s*\{[^}]*"(start|dev|serve)"\s*:/s, body) -> :app
      Regex.match?(~r/"(main|module|exports|types)"\s*:/, body) -> :library
      true -> :unknown
    end
  end

  defp app_or_library(dir, {file, _}, _entries)
       when file in ["pyproject.toml", "setup.py", "requirements.txt"] do
    if File.regular?(Path.join(dir, "main.py")) or File.regular?(Path.join(dir, "app.py")),
      do: :app,
      else: :library
  end

  defp app_or_library(_dir, _manifest, _entries), do: :library

  # SDK is claimed only on *naming* evidence — a declared package name or path
  # segment that says "sdk" — or a caller hint from an `sdks/` parent.
  defp sdk?(dir, declared_name, hint) do
    base = Path.basename(Path.expand(dir))
    parent = dir |> Path.expand() |> Path.dirname() |> Path.basename()

    hint == :sdk or
      parent in ["sdks", "sdk", "clients"] or
      Regex.match?(~r/(^|[-_\/])sdk([-_\/]|$)/i, base) or
      (is_binary(declared_name) and Regex.match?(~r/(^|[-_\/@])sdk([-_\/]|$)/i, declared_name))
  end

  defp docs_only?(dir, entries, manifest) do
    base = Path.basename(Path.expand(dir))

    cond do
      manifest != nil -> false
      base in ["docs", "doc", "documentation", "website"] -> true
      entries == [] -> false
      true -> Enum.all?(entries, &(Path.extname(&1) in [".md", ".mdx", ".rst", ".txt", ""]))
    end
  end

  defp tests_only?(dir, _entries, manifest) do
    manifest == nil and Path.basename(Path.expand(dir)) in ["test", "tests", "spec", "e2e"]
  end

  # ── Infra evidence ────────────────────────────────────────────────────

  # Returns {language, evidence_filename} or nil.
  defp infra_evidence(dir) do
    cond do
      File.regular?(Path.join(dir, "Chart.yaml")) -> {"Helm", "Chart.yaml"}
      File.regular?(Path.join(dir, "main.tf")) -> {"Terraform", "main.tf"}
      File.regular?(Path.join(dir, "terragrunt.hcl")) -> {"Terraform", "terragrunt.hcl"}
      File.regular?(Path.join(dir, "kustomization.yaml")) -> {"Kustomize", "kustomization.yaml"}
      File.regular?(Path.join(dir, "template.yaml")) -> {"CloudFormation", "template.yaml"}
      Path.wildcard(Path.join(dir, "*.tf")) != [] -> {"Terraform", "*.tf"}
      true -> nil
    end
  end

  # ── IO helpers (never raise into the walk) ────────────────────────────

  defp read_capped(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @read_cap)) do
      {:ok, data} when is_binary(data) -> data
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp safe_ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.reject(entries, &String.starts_with?(&1, "."))
      _ -> []
    end
  end
end
