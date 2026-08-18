defmodule OptimalSystemAgent.Agent.Safety.PathPolicy do
  @moduledoc """
  The single sensitive-path / blocked-write-path policy shared by every
  file-touching builtin.

  ## Why this module exists

  The same blocklist was copy-pasted into six constants modules and two tool
  modules. They drifted, and the drift was a credential leak: only the
  `file_read` list named `~/.osa/subscriptions.json`, so `diff` — which
  carries its own copy — would happily render the operator's paid-account
  bearer tokens into a tool observation:

      diff(file_a: "~/.osa/subscriptions.json", file_b: "/dev/null")

  A blocklist that exists in N places protects N different things. There is
  now one list, here.

  ## Structural matching, not substring matching

  The old guards were `String.contains?(path, pattern)` against patterns like
  `"/var/"`, `"/usr/"`, `"/bin/"` and `".env"`. Substring matching on a path
  has no notion of a component boundary, so it both over- and under-matches:

    * `"/var/"` blocked every Symfony/Laravel/Composer project, because
      `~/projects/shop/var/cache/` contains `/var/`. Same for `"/bin/"` and
      any project with a `bin/` directory, and `"/usr/"` for anything under a
      directory named `usr`.
    * `".env"` blocked `.envrc` (direnv), `docs/.env.example`, and a directory
      called `myapp.environment` — while a file literally named `.env` two
      directories up was blocked for the wrong reason.

  Every rule below is therefore expressed over **path components**:

    * `{:root, "/etc"}`     — the path IS `/etc` or lies underneath it, from
                              the filesystem root. `~/proj/etc/x` does not match.
    * `{:dir, ".ssh"}`      — some component is exactly `.ssh` (whole subtree).
    * `{:suffix, [..]}`     — the trailing components match this sequence, e.g.
                              `[".aws", "credentials"]`.
    * `{:base, ".netrc"}`   — the final component is exactly this.
    * `:dotenv`             — the final component is `.env` or `.env.<env>`,
                              excluding the documentation variants
                              (`.env.example` and friends) and `.envrc`.

  Callers are expected to pass a path that has already been canonicalised by
  `OptimalSystemAgent.Agent.Safety.PathCanon`; `canonical/1` is re-exported
  here so a caller that has only a raw string can do it in one step.
  """

  alias OptimalSystemAgent.Agent.Safety.PathCanon

  # ── Sensitive: never readable ─────────────────────────────────────────
  #
  # `.osa/subscriptions.json` holds subscription bearer tokens for the
  # operator's paid accounts. An agent that can read its own credential store
  # is an exfiltration primitive: one prompt-injected instruction inside a
  # file it was asked to summarise is enough to get the token into a tool
  # call. It is denied by name here, for every tool at once — which is the
  # whole point of this module.
  @sensitive_rules [
    {:suffix, [".ssh", "id_rsa"]},
    {:suffix, [".ssh", "id_ed25519"]},
    {:suffix, [".ssh", "id_ecdsa"]},
    {:suffix, [".ssh", "id_dsa"]},
    {:dir, ".gnupg"},
    {:suffix, [".aws", "credentials"]},
    {:suffix, [".osa", "subscriptions.json"]},
    {:root, "/etc/shadow"},
    {:root, "/etc/sudoers"},
    {:root, "/etc/master.passwd"},
    {:base, ".netrc"},
    {:base, ".npmrc"},
    {:base, ".pypirc"},
    :dotenv
  ]

  # ── Blocked for writes: OS directories and credential/config stores ───
  #
  # `.git` is here because writing into a repository's `.git/` is arbitrary
  # code execution on the user's next git invocation: `core.hooksPath` in
  # `.git/config`, or a script dropped in `.git/hooks/`, runs unprompted.
  # `OptimalSystemAgent.Git` already documents that exact attack for repos OSA
  # *reads*; there is no reason to leave the write side open. Note that the
  # dotfile-outside-`~/.osa` guard does NOT cover this: it only inspects the
  # first component under `$HOME`, so `~/projects/anything/.git/config` sailed
  # through.
  @blocked_write_rules [
    {:dir, ".ssh"},
    {:dir, ".gnupg"},
    {:dir, ".aws"},
    {:dir, ".git"},
    {:root, "/etc"},
    {:root, "/boot"},
    {:root, "/usr"},
    {:root, "/bin"},
    {:root, "/sbin"},
    {:root, "/var"},
    :dotenv
  ]

  # `.env.example` and friends are documentation, committed to public repos by
  # design. They are not credential stores and blocking them only breaks
  # ordinary work.
  @dotenv_doc_suffixes ~w(example sample template dist default defaults)

  # `/private/tmp` is NOT listed here even though the write list carries it:
  # `normalize_roots/1` canonicalises every root, so "/tmp" already becomes
  # "/private/tmp/" on macOS. The write list's extra entry is redundant rather
  # than load-bearing. What was actually broken was the CALLER side - see
  # `within_read_roots?/1`.
  @default_read_roots ["~", "/tmp"]
  @default_write_roots ["~", "/tmp", "/private/tmp"]

  # ── Predicates ────────────────────────────────────────────────────────

  @doc "Canonical (fully symlink-resolved, `~`-expanded) form of `path`."
  @spec canonical(term()) :: String.t()
  def canonical(path), do: PathCanon.canonicalize(path)

  @doc """
  True when `path` names a credential store or other secret that no tool may
  read. Expects an already-canonical path.
  """
  @spec sensitive?(term()) :: boolean()
  def sensitive?(path) when is_binary(path), do: match_any?(@sensitive_rules, path)
  def sensitive?(_), do: true

  @doc """
  True when `path` lies in a location no tool may write to (OS directories,
  credential stores, or a git control directory). Expects an already-canonical
  path.
  """
  @spec blocked_write?(term()) :: boolean()
  def blocked_write?(path) when is_binary(path), do: match_any?(@blocked_write_rules, path)
  def blocked_write?(_), do: true

  @doc """
  True when `path` is a dotfile or dotdirectory directly under `$HOME` that is
  not inside `~/.osa/`. Shell rc files, credential directories and editor
  configs live there, and rewriting them is indistinguishable from persistence.
  """
  @spec dotfile_outside_osa?(term()) :: boolean()
  def dotfile_outside_osa?(path) when is_binary(path) do
    home = Path.expand("~")
    osa = Path.expand("~/.osa") <> "/"

    case String.split_at(path, byte_size(home)) do
      {^home, "/" <> rest} ->
        first = rest |> String.split("/") |> List.first() |> to_string()
        String.starts_with?(first, ".") and not String.starts_with?(path <> "/", osa)

      _ ->
        false
    end
  end

  def dotfile_outside_osa?(_), do: false

  # ── Allowlist roots ───────────────────────────────────────────────────

  @doc """
  The roots contributed by the CURRENT SESSION's workspace: its resolved
  working directory plus any directory the operator added with `/add-dir`.

  ## Why this is not optional

  The configured roots below are a static, node-wide allowlist that defaults to
  `["~", "/tmp"]`. It has never known anything about the directory a session
  was actually told to work in. On a developer machine that is invisible,
  because the project lives under `$HOME` and so is covered by `~` for the
  wrong reason. In a container it is fatal: with `HOME=/root` and a workspace of
  `/app`, `within_roots?/2` rejects every path in the workspace and the agent is
  told `Access denied: /app/… is outside allowed paths` for the files it was
  given the job of editing. Measured in a Terminal-Bench run: three of three
  tasks hit it, one abandoned the task, one fell back to heredocs through the
  shell, and all three asked for `/add-dir /app` — which could not have helped,
  because nothing on this path consulted `additionalDirectories` either.

  This does not widen the boundary to arbitrary paths: it adds exactly the
  directory the session declared, and the directories the operator explicitly
  granted. Everything outside them is denied as before. `blocked_write?/1`
  (`/etc`, `/usr`, `.git`, credential stores) is applied FIRST in
  `check_write/2` and is unaffected — a workspace root cannot unblock those.

  Fails closed: any error resolving the session scope yields no extra roots.
  """
  @spec workspace_roots() :: [String.t()]
  def workspace_roots do
    extra =
      try do
        OptimalSystemAgent.Permissions.additional_directories()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    [OptimalSystemAgent.Workspace.Cwd.get() | extra]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> normalize_roots()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc "Configured read roots plus the session workspace, canonicalised and slash-terminated."
  @spec read_roots() :: [String.t()]
  def read_roots do
    configured =
      :optimal_system_agent
      |> Application.get_env(:allowed_read_paths, @default_read_roots)
      |> normalize_roots()

    Enum.uniq(configured ++ workspace_roots())
  end

  @doc "Configured write roots plus the session workspace, canonicalised and slash-terminated."
  @spec write_roots() :: [String.t()]
  def write_roots do
    configured =
      :optimal_system_agent
      |> Application.get_env(:allowed_write_paths, default_write_roots())
      |> normalize_roots()

    Enum.uniq(configured ++ workspace_roots())
  end

  @doc "Default write roots including this platform's temp directory."
  @spec default_write_roots() :: [String.t()]
  def default_write_roots do
    tmp = System.tmp_dir!()
    if tmp in @default_write_roots, do: @default_write_roots, else: @default_write_roots ++ [tmp]
  end

  @doc "Default read roots."
  @spec default_read_roots() :: [String.t()]
  def default_read_roots, do: @default_read_roots

  @doc """
  True when `path` sits under one of `roots`. Comparison is slash-terminated on
  both sides so `/tmp-evil` never matches the root `/tmp`.
  """
  @spec within_roots?(String.t(), [String.t()]) :: boolean()
  def within_roots?(path, roots) do
    check = if String.ends_with?(path, "/"), do: path, else: path <> "/"
    Enum.any?(roots, &String.starts_with?(check, &1))
  end

  # ── Composite decisions ───────────────────────────────────────────────

  @doc """
  `:ok` or `{:deny, reason}` for reading `path`. `path` may be raw; it is
  canonicalised here. `display` is what appears in the refusal text.
  """
  @spec check_read(String.t(), String.t()) :: :ok | {:deny, String.t()}
  def check_read(path, display \\ nil) do
    display = display || path
    canonical = canonical(path)

    cond do
      sensitive?(canonical) ->
        {:deny, "Access denied: #{display} is a sensitive file"}

      not within_roots?(canonical, read_roots()) ->
        {:deny, "Access denied: #{display} is outside allowed paths"}

      true ->
        :ok
    end
  end

  @doc """
  `:ok` or `{:deny, reason}` for reading a file the USER explicitly chose —
  a drag-and-drop, a clipboard paste of a path, an `@file` mention, a file
  picker. `path` may be raw; it is canonicalised here.

  This is deliberately weaker than `check_read/2` and the difference is exactly
  one rule: the allowed-roots confinement does not apply.

  `check_read/2` exists because the *model* picks the path. A model-chosen path
  is attacker-influenced (a prompt injection inside a file it was asked to
  summarise is enough), so it must stay inside `read_roots/0`. A user-chosen
  path carries the user's own consent: a screenshot lands in `$TMPDIR`, on the
  Desktop, on a mounted volume — never inside the workspace — so confining it
  to `read_roots/0` refuses the exact file the user just asked us to look at.
  v1.0.79 routed image attachments through `check_read/2` and did precisely
  that.

  Everything that is NOT about location is kept:

    * canonicalisation, so a symlink cannot make the user consent to one file
      and hand us another,
    * the sensitive-file blocklist — a mis-dragged `~/.ssh/id_rsa` is still
      refused, and refusing it costs the user nothing since no one means to
      attach their private key.

  Size caps and content sniffing are the caller's job (see
  `Agent.Loop.MessageHandler`); they apply to both trust levels.
  """
  @spec check_user_attachment(String.t(), String.t() | nil) :: :ok | {:deny, String.t()}
  def check_user_attachment(path, display \\ nil) do
    display = display || path
    canonical = canonical(path)

    if sensitive?(canonical) do
      {:deny, "Access denied: #{display} is a sensitive file"}
    else
      :ok
    end
  end

  @doc """
  Trust-aware read decision. `:model` (the default everywhere a source is not
  known) is the confined `check_read/2`; `:user` is `check_user_attachment/2`.

  Call this from any ingestion path that can be reached by BOTH an explicit
  user action and a model-authored value, so the two are never conflated by
  accident.
  """
  @spec check_read_as(:user | :model, String.t(), String.t() | nil) :: :ok | {:deny, String.t()}
  def check_read_as(:user, path, display), do: check_user_attachment(path, display)
  def check_read_as(_model, path, display), do: check_read(path, display || path)

  @doc """
  `:ok` or `{:deny, reason}` for writing `path`. `path` may be raw; it is
  canonicalised here, so an intermediate directory symlink cannot smuggle the
  target out of the allowed roots.

  This is the ONLY write decision. `file_edit`, `file_write`, `multi_file_edit`
  and `notebook_edit` each used to carry their own variant, and the variants
  disagreed: `multi_file_edit` resolved no symlinks and had no dotfile clause
  at all, so it could write where its two siblings refused.
  """
  @spec check_write(String.t(), String.t() | nil) :: :ok | {:deny, String.t()}
  def check_write(path, display \\ nil) do
    display = display || path
    expanded = Path.expand(path)
    canonical = canonical(expanded)
    through_symlink? = canonical != expanded

    cond do
      # Guard on the PRE-resolution path too: a protected dotfile such as
      # ~/.zshrc is protected by its name and location even when it is a
      # symlink into an otherwise-allowed directory.
      dotfile_outside_osa?(expanded) ->
        {:deny, "Access denied: #{display} is a protected dotfile outside ~/.osa/"}

      dotfile_outside_osa?(canonical) ->
        {:deny, "Access denied: #{display} is a protected dotfile outside ~/.osa/"}

      blocked_write?(canonical) ->
        {:deny, "Access denied: #{display} targets a protected location"}

      through_symlink? and not within_roots?(canonical, write_roots()) ->
        {:deny, "Access denied: #{display} resolves through a symlink to a protected location"}

      not within_roots?(canonical, write_roots()) ->
        {:deny, "Access denied: #{display} is outside allowed paths"}

      true ->
        :ok
    end
  end

  @doc """
  True when `path` may be written. Thin boolean wrapper over `check_write/2`
  for call sites that only need a yes/no.
  """
  @spec write_allowed?(String.t()) :: boolean()
  def write_allowed?(path), do: check_write(path) == :ok

  @doc """
  True when `path` may be read. Thin boolean wrapper over `check_read/2`.
  """
  @spec read_allowed?(String.t()) :: boolean()
  def read_allowed?(path), do: check_read(path) == :ok

  # ── Legacy pattern lists ──────────────────────────────────────────────
  #
  # Retained so the per-tool `Constants` modules keep their public shape for
  # prompt text and for tests that assert "the guard knows about .ssh". These
  # are DESCRIPTIONS of the rules, not the matcher — nothing should do
  # `String.contains?` with them ever again.

  @doc "Human-readable rendering of the sensitive-path rules."
  @spec sensitive_patterns() :: [String.t()]
  def sensitive_patterns, do: Enum.map(@sensitive_rules, &describe/1)

  @doc "Human-readable rendering of the blocked-write rules."
  @spec blocked_write_patterns() :: [String.t()]
  def blocked_write_patterns, do: Enum.map(@blocked_write_rules, &describe/1)

  defp describe({:root, abs}), do: abs <> "/"
  defp describe({:dir, name}), do: name <> "/"
  defp describe({:suffix, parts}), do: Enum.join(parts, "/")
  defp describe({:base, name}), do: name
  defp describe(:dotenv), do: ".env"

  # ── Matching ──────────────────────────────────────────────────────────

  defp match_any?(rules, path) do
    parts = components(path)
    base = List.last(parts) || ""
    Enum.any?(rules, &matches?(&1, path, parts, base))
  end

  # Absolute, root-anchored: the path IS the directory or lies under it.
  defp matches?({:root, abs}, path, _parts, _base) do
    path == abs or String.starts_with?(path, abs <> "/")
  end

  # Any component equals `name` — the whole subtree is covered.
  defp matches?({:dir, name}, _path, parts, _base), do: name in parts

  # The trailing components equal `seq`.
  defp matches?({:suffix, seq}, _path, parts, _base) do
    n = length(seq)
    length(parts) >= n and Enum.take(parts, -n) == seq
  end

  defp matches?({:base, name}, _path, _parts, base), do: base == name

  defp matches?(:dotenv, _path, _parts, base), do: dotenv?(base)

  # `.env` and per-environment variants (`.env.local`, `.env.production`) hold
  # secrets. `.envrc` does not start with `.env.` and is not matched; the
  # documentation variants are excluded by name.
  defp dotenv?(".env"), do: true

  defp dotenv?(".env." <> rest) do
    rest != "" and String.downcase(rest) not in @dotenv_doc_suffixes
  end

  defp dotenv?(_), do: false

  defp components(path) do
    case Path.split(path) do
      ["/" | rest] -> rest
      other -> other
    end
  end

  @doc """
  Whether `path` sits under a configured read root.

  Canonicalises `path` first, which is the whole point: `read_roots/0` returns
  canonical roots (`normalize_roots/1` resolves every symlink), so comparing a
  merely `Path.expand`-ed path against them puts the two sides in different
  namespaces. On macOS `/tmp` canonicalises to `/private/tmp`, so
  `String.starts_with?("/tmp/x/", "/private/tmp/")` is false and a legitimate
  read is denied with "outside allowed paths".

  Five handlers had each written this comparison themselves and five got it
  wrong the same way. Callers should use this rather than reimplementing it.
  """
  @spec within_read_roots?(term()) :: boolean()
  def within_read_roots?(path), do: within?(path, read_roots())

  @doc "Whether `path` sits under a configured write root. See `within_read_roots?/1`."
  @spec within_write_roots?(term()) :: boolean()
  def within_write_roots?(path), do: within?(path, write_roots())

  defp within?(path, roots) do
    check = path |> canonical() |> slash_terminate()
    Enum.any?(roots, &String.starts_with?(check, &1))
  end

  defp slash_terminate(""), do: ""
  defp slash_terminate(p), do: if(String.ends_with?(p, "/"), do: p, else: p <> "/")

  defp normalize_roots(roots) do
    Enum.map(roots, fn root ->
      canonical = canonical(root)
      if String.ends_with?(canonical, "/"), do: canonical, else: canonical <> "/"
    end)
  end
end
