defmodule OptimalSystemAgent.Tools.Builtins.ShellExecute.Parser do
  @moduledoc """
  Structured shell-command analysis for `shell_execute` permissioning.

  Elixir port of opencode's `tool/shell.ts` + `permission/arity.ts` scanning
  layer. Elixir has no first-class tree-sitter binding, so instead of an AST we
  run a robust hand-written **tokenizer** that is quote/escape/substitution
  aware. From the token stream we:

    1. Split the command into segments on `;`, `&&`, `||`, `|`, `&`
       (operators inside quotes / `$(...)` / `${...}` / backticks never split).
    2. For each segment extract the command *head* and its file-path arguments
       (flags dropped, redirections and their operands dropped).
    3. Expand `~`, `~/…`, `$HOME`, `${HOME}` in each path arg, strip glob
       prefixes (`src/*.ex` → `src/`), and skip anything still *dynamic*
       (`$(...)`, backticks, other `$VAR`) — those cannot be resolved
       statically.
    4. Resolve each remaining path against the session cwd and flag any that
       lands **outside** the working directory as an "external directory"
       (only for file-mutating commands — reads/navigation are not flagged, in
       keeping with OSA's un-caged philosophy).
    5. Compute an **arity prefix** per segment (`git checkout …` → `git
       checkout`, `npm run dev` → `npm run dev`, `ls -la` → `ls`) so an approved
       command can yield an "always allow `<prefix> *`" rule instead of pinning
       the exact string.

  This module is pure and side-effect free apart from `File.dir?/1` (used to
  decide whether a resolved path is itself a directory or a file whose parent
  directory is the touched dir). It never executes anything.
  """

  # ── Command classification sets ───────────────────────────────────────

  # Heads whose non-flag arguments are file paths worth resolving. Used for
  # path extraction. Mirrors opencode's FILES/CWD sets (PowerShell aliases
  # dropped — OSA targets POSIX shells).
  @path_commands ~w(
    rm cp mv mkdir touch chmod chown cat ln tee rsync install
    cd chdir pushd popd
  )

  # Heads that, when they touch a path OUTSIDE the session cwd, warrant an
  # "external directory" ask. Deliberately EXCLUDES read-only `cat` and
  # navigation `cd`/`pushd`/`popd` so ordinary reads (`cat /etc/os-release`)
  # and `cd /tmp` stay friction-free — only real filesystem mutation escalates.
  @external_scan_commands ~w(
    rm cp mv mkdir touch chmod chown ln tee rsync install
  )

  # Navigation commands: they get path-scanned but never contribute an
  # "always allow" arity pattern (matches opencode's CWD guard).
  @cwd_commands ~w(cd chdir pushd popd)

  # ── Arity table (ported from opencode permission/arity.ts) ────────────
  #
  # Maps a command *prefix* string → the number of leading tokens that define
  # the human-understandable command. Flags never count as tokens. Longest
  # matching prefix wins.
  @arity %{
    "cat" => 1,
    "cd" => 1,
    "chmod" => 1,
    "chown" => 1,
    "cp" => 1,
    "echo" => 1,
    "env" => 1,
    "export" => 1,
    "grep" => 1,
    "kill" => 1,
    "killall" => 1,
    "ln" => 1,
    "ls" => 1,
    "mkdir" => 1,
    "mv" => 1,
    "ps" => 1,
    "pwd" => 1,
    "rm" => 1,
    "rmdir" => 1,
    "sleep" => 1,
    "source" => 1,
    "tail" => 1,
    "touch" => 1,
    "unset" => 1,
    "which" => 1,
    "aws" => 3,
    "az" => 3,
    "bazel" => 2,
    "brew" => 2,
    "bun" => 2,
    "bun run" => 3,
    "bun x" => 3,
    "cargo" => 2,
    "cargo add" => 3,
    "cargo run" => 3,
    "cdk" => 2,
    "cf" => 2,
    "cmake" => 2,
    "composer" => 2,
    "consul" => 2,
    "consul kv" => 3,
    "crictl" => 2,
    "deno" => 2,
    "deno task" => 3,
    "doctl" => 3,
    "docker" => 2,
    "docker builder" => 3,
    "docker compose" => 3,
    "docker container" => 3,
    "docker image" => 3,
    "docker network" => 3,
    "docker volume" => 3,
    "eksctl" => 2,
    "eksctl create" => 3,
    "firebase" => 2,
    "flyctl" => 2,
    "gcloud" => 3,
    "gh" => 3,
    "git" => 2,
    "git config" => 3,
    "git remote" => 3,
    "git stash" => 3,
    "go" => 2,
    "gradle" => 2,
    "helm" => 2,
    "heroku" => 2,
    "hugo" => 2,
    "ip" => 2,
    "ip addr" => 3,
    "ip link" => 3,
    "ip netns" => 3,
    "ip route" => 3,
    "kind" => 2,
    "kind create" => 3,
    "kubectl" => 2,
    "kubectl kustomize" => 3,
    "kubectl rollout" => 3,
    "kustomize" => 2,
    "make" => 2,
    "mc" => 2,
    "mc admin" => 3,
    "minikube" => 2,
    "mongosh" => 2,
    "mysql" => 2,
    "mvn" => 2,
    "ng" => 2,
    "npm" => 2,
    "npm exec" => 3,
    "npm init" => 3,
    "npm run" => 3,
    "npm view" => 3,
    "nvm" => 2,
    "nx" => 2,
    "openssl" => 2,
    "openssl req" => 3,
    "openssl x509" => 3,
    "pip" => 2,
    "pipenv" => 2,
    "pnpm" => 2,
    "pnpm dlx" => 3,
    "pnpm exec" => 3,
    "pnpm run" => 3,
    "poetry" => 2,
    "podman" => 2,
    "podman container" => 3,
    "podman image" => 3,
    "psql" => 2,
    "pulumi" => 2,
    "pulumi stack" => 3,
    "pyenv" => 2,
    "python" => 2,
    "rake" => 2,
    "rbenv" => 2,
    "redis-cli" => 2,
    "rustup" => 2,
    "serverless" => 2,
    "sfdx" => 3,
    "skaffold" => 2,
    "sls" => 2,
    "sst" => 2,
    "swift" => 2,
    "systemctl" => 2,
    "terraform" => 2,
    "terraform workspace" => 3,
    "tmux" => 2,
    "turbo" => 2,
    "ufw" => 2,
    "vault" => 2,
    "vault auth" => 3,
    "vault kv" => 3,
    "vercel" => 2,
    "volta" => 2,
    "wp" => 2,
    "yarn" => 2,
    "yarn dlx" => 3,
    "yarn run" => 3
  }

  @type token :: {:word, String.t()} | {:op, String.t()} | {:redir, String.t()}

  @type segment_info :: %{
          head: String.t() | nil,
          prefix: [String.t()],
          always: String.t() | nil,
          paths: [String.t()],
          external_dirs: [String.t()]
        }

  @type scan :: %{
          segments: [segment_info],
          external_dirs: [String.t()],
          always: [String.t()],
          paths: [String.t()]
        }

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Full structured scan of `command` resolved against `cwd`.

  Returns a map with:

    * `:segments`      — per-segment analysis
    * `:external_dirs` — unique directories touched OUTSIDE `cwd` by
      file-mutating commands
    * `:always`        — unique "`<prefix> *`" always-allow patterns
    * `:paths`         — unique resolved absolute paths referenced
  """
  @spec scan(String.t(), String.t()) :: scan
  def scan(command, cwd) when is_binary(command) do
    root = Path.expand(safe_cwd(cwd))

    segs =
      command
      |> segments()
      |> Enum.map(&analyze_segment(&1, root))

    %{
      segments: segs,
      external_dirs: segs |> Enum.flat_map(& &1.external_dirs) |> Enum.uniq(),
      always: segs |> Enum.map(& &1.always) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      paths: segs |> Enum.flat_map(& &1.paths) |> Enum.uniq()
    }
  end

  @doc """
  Tokenize a shell command into `{:word, raw}`, `{:op, op}`, and `{:redir, op}`
  tokens. Quotes, escapes, `$(...)`, `${...}`, and backticks are respected so
  operators appearing inside them do not split the stream. Word tokens keep
  their raw text (quotes included); use `unquote_token/1` to strip outer quotes.
  """
  @spec tokenize(String.t()) :: [token]
  def tokenize(command) when is_binary(command), do: lex(command, [], [])

  @doc """
  Split a command into segments on the connectives `;`, `&&`, `||`, `|`, `&`.
  Each segment is a list of `{:word, _}` / `{:redir, _}` tokens.
  """
  @spec segments(String.t()) :: [[token]]
  def segments(command) when is_binary(command) do
    command
    |> tokenize()
    |> split_on_ops([], [])
  end

  @doc """
  The arity prefix for a plain (already-unquoted) token list: the leading
  tokens that define the human-understandable command, with flags removed and
  the head reduced to its basename.

      iex> arity_prefix(["git", "checkout", "main"])
      ["git", "checkout"]
      iex> arity_prefix(["npm", "run", "dev"])
      ["npm", "run", "dev"]
      iex> arity_prefix(["ls", "-la"])
      ["ls"]
  """
  @spec arity_prefix([String.t()]) :: [String.t()]
  def arity_prefix(tokens) when is_list(tokens) do
    case Enum.reject(tokens, &flag?/1) do
      [] -> []
      [head | rest] -> arity_take([normalize_name(head) | rest])
    end
  end

  @doc """
  Strip a single pair of matching outer quotes from a raw token.
  """
  @spec unquote_token(String.t()) :: String.t()
  def unquote_token(raw), do: unq(raw)

  @doc """
  Expand and resolve a single raw path argument against `cwd`.

  Returns `{:ok, absolute_path}` or `:skip` when the argument is a pure glob or
  still dynamic (contains `$(...)`, a backtick, or an unresolved `$VAR`).
  """
  @spec expand_path(String.t(), String.t()) :: {:ok, String.t()} | :skip
  def expand_path(raw, cwd) do
    v0 = unq(raw)
    v1 = home_expand(v0)
    file = glob_prefix(v1)

    cond do
      is_nil(file) or file == "" -> :skip
      dynamic?(file) -> :skip
      true -> {:ok, Path.expand(file, Path.expand(safe_cwd(cwd)))}
    end
  end

  # ── Segment analysis ──────────────────────────────────────────────────

  defp analyze_segment(tokens, cwd) do
    case strip_redir(tokens) do
      [] ->
        %{head: nil, prefix: [], always: nil, paths: [], external_dirs: []}

      [head_raw | _] = words ->
        head = normalize_name(head_raw)

        paths =
          if head in @path_commands do
            words
            |> path_arg_candidates(head)
            |> Enum.flat_map(fn raw ->
              case expand_path(raw, cwd) do
                {:ok, p} -> [p]
                :skip -> []
              end
            end)
            |> Enum.uniq()
          else
            []
          end

        external =
          if head in @external_scan_commands do
            paths
            |> Enum.map(&touched_dir/1)
            |> Enum.filter(&external?(&1, cwd))
            |> Enum.uniq()
          else
            []
          end

        %{
          head: head,
          prefix: prefix_tokens(words, head),
          always: always_pattern(words, head),
          paths: paths,
          external_dirs: external
        }
    end
  end

  # Candidate path arguments: everything after the head that is not a flag and
  # (for chmod) not a symbolic mode like `+x`.
  defp path_arg_candidates([_head | args], head) do
    args
    |> Enum.map(&{&1, unq(&1)})
    |> Enum.reject(fn {_raw, v} -> flag?(v) end)
    |> Enum.reject(fn {_raw, v} -> head == "chmod" and String.starts_with?(v, "+") end)
    |> Enum.map(fn {raw, _v} -> raw end)
  end

  defp path_arg_candidates([], _head), do: []

  defp prefix_tokens(words, head) do
    if head in @cwd_commands, do: [], else: arity_prefix(Enum.map(words, &unq/1))
  end

  defp always_pattern(words, head) do
    if head in @cwd_commands do
      nil
    else
      case arity_prefix(Enum.map(words, &unq/1)) do
        [] -> nil
        prefix -> Enum.join(prefix, " ") <> " *"
      end
    end
  end

  # ── Arity resolution ──────────────────────────────────────────────────

  defp arity_take(tokens) do
    Enum.take(tokens, arity_lookup(tokens))
  end

  defp arity_lookup(tokens) do
    len = length(tokens)

    Enum.reduce_while(len..1//-1, 1, fn take, _acc ->
      key = tokens |> Enum.take(take) |> Enum.join(" ")

      case Map.get(@arity, key) do
        nil -> {:cont, 1}
        arity -> {:halt, arity}
      end
    end)
  end

  # ── Path expansion helpers ────────────────────────────────────────────

  defp home_expand(v) do
    home = user_home()

    v =
      cond do
        home == "" -> v
        v == "~" -> home
        String.starts_with?(v, "~/") -> home <> binary_part(v, 1, byte_size(v) - 1)
        true -> v
      end

    if home == "" do
      v
    else
      Regex.replace(~r/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/, v, fn _ -> home end)
    end
  end

  # First glob-metacharacter split: nil when the arg is a pure glob (`*.ex`),
  # the literal prefix up to the first glob char otherwise (`src/*.ex` → `src/`).
  defp glob_prefix(v) do
    case Regex.run(~r/[*?\[]/, v, return: :index) do
      nil -> v
      [{0, _}] -> nil
      [{i, _}] -> binary_part(v, 0, i)
    end
  end

  # A value is still dynamic (unresolvable statically) if it references a shell
  # variable / command substitution / backtick that we did not expand.
  defp dynamic?(v) do
    String.contains?(v, "$") or String.contains?(v, "`")
  end

  defp touched_dir(path) do
    if File.dir?(path), do: path, else: Path.dirname(path)
  end

  defp external?(dir, cwd) do
    not (dir == cwd or String.starts_with?(dir, ensure_trailing_slash(cwd)))
  end

  defp ensure_trailing_slash(dir) do
    if String.ends_with?(dir, "/"), do: dir, else: dir <> "/"
  end

  defp normalize_name(raw) do
    raw
    |> unq()
    |> String.replace(~r/^\\+/, "")
    |> Path.basename()
  end

  defp flag?(v), do: String.starts_with?(v, "-")

  defp unq(t) when is_binary(t) do
    size = byte_size(t)

    if size >= 2 do
      first = binary_part(t, 0, 1)
      last = binary_part(t, size - 1, 1)

      if first in ["\"", "'"] and first == last do
        binary_part(t, 1, size - 2)
      else
        t
      end
    else
      t
    end
  end

  defp user_home do
    System.user_home() || System.get_env("HOME") || ""
  end

  defp safe_cwd(cwd) when is_binary(cwd) and cwd != "", do: cwd
  defp safe_cwd(_), do: "."

  # ── Segment splitting ─────────────────────────────────────────────────

  defp split_on_ops([], cur, acc) do
    acc = if cur == [], do: acc, else: [Enum.reverse(cur) | acc]
    Enum.reverse(acc)
  end

  defp split_on_ops([{:op, _} | rest], cur, acc) do
    acc = if cur == [], do: acc, else: [Enum.reverse(cur) | acc]
    split_on_ops(rest, [], acc)
  end

  defp split_on_ops([tok | rest], cur, acc) do
    split_on_ops(rest, [tok | cur], acc)
  end

  # Drop redirection operators together with their target operand, so
  # `foo > out.txt` never resolves `out.txt` as a positional path arg.
  defp strip_redir([{:redir, _}, {:word, _} | rest]), do: strip_redir(rest)
  defp strip_redir([{:redir, _} | rest]), do: strip_redir(rest)
  defp strip_redir([{:word, w} | rest]), do: [w | strip_redir(rest)]
  defp strip_redir([]), do: []

  # ── Tokenizer ─────────────────────────────────────────────────────────
  #
  # `cur` is a reversed list of raw binary fragments for the in-progress word;
  # `toks` is the reversed accumulator of emitted tokens.

  defp lex(<<>>, cur, toks), do: flush(cur, toks) |> Enum.reverse()

  # Single-quoted string — everything literal until the next single quote.
  defp lex(<<?', rest::binary>>, cur, toks) do
    {seg, rest2} = read_single(rest, ["'"])
    lex(rest2, [seg | cur], toks)
  end

  # Double-quoted string — honor backslash escapes, stop at the closing quote.
  defp lex(<<?", rest::binary>>, cur, toks) do
    {seg, rest2} = read_double(rest, ["\""])
    lex(rest2, [seg | cur], toks)
  end

  # $( … ) command substitution (balanced) — consumed whole, never split.
  defp lex(<<?$, ?(, rest::binary>>, cur, toks) do
    {seg, rest2} = read_subst(rest, ["$("], 1)
    lex(rest2, [seg | cur], toks)
  end

  # ${ … } parameter expansion — consumed whole.
  defp lex(<<?$, ?{, rest::binary>>, cur, toks) do
    {seg, rest2} = read_brace(rest, ["${"])
    lex(rest2, [seg | cur], toks)
  end

  # Backtick substitution — consumed whole.
  defp lex(<<?`, rest::binary>>, cur, toks) do
    {seg, rest2} = read_backtick(rest, ["`"])
    lex(rest2, [seg | cur], toks)
  end

  # Backslash escape of the next character.
  defp lex(<<?\\, c, rest::binary>>, cur, toks), do: lex(rest, [<<?\\, c>> | cur], toks)
  defp lex(<<?\\>>, cur, toks), do: lex(<<>>, [<<?\\>> | cur], toks)

  # Whitespace ends the current word.
  defp lex(<<c, rest::binary>>, cur, toks) when c in [?\s, ?\t, ?\n, ?\r] do
    lex(rest, [], flush(cur, toks))
  end

  # Connective operators (multi-char before single-char).
  defp lex(<<?&, ?&, rest::binary>>, cur, toks),
    do: lex(rest, [], [{:op, "&&"} | flush(cur, toks)])

  defp lex(<<?&, rest::binary>>, cur, toks), do: lex(rest, [], [{:op, "&"} | flush(cur, toks)])

  defp lex(<<?|, ?|, rest::binary>>, cur, toks),
    do: lex(rest, [], [{:op, "||"} | flush(cur, toks)])

  defp lex(<<?|, rest::binary>>, cur, toks), do: lex(rest, [], [{:op, "|"} | flush(cur, toks)])
  defp lex(<<?;, rest::binary>>, cur, toks), do: lex(rest, [], [{:op, ";"} | flush(cur, toks)])

  # Redirections (kept as their own token; do not split segments).
  defp lex(<<?>, ?>, rest::binary>>, cur, toks),
    do: lex(rest, [], [{:redir, ">>"} | flush(cur, toks)])

  defp lex(<<?>, rest::binary>>, cur, toks), do: lex(rest, [], [{:redir, ">"} | flush(cur, toks)])
  defp lex(<<?<, rest::binary>>, cur, toks), do: lex(rest, [], [{:redir, "<"} | flush(cur, toks)])

  # Ordinary byte — accumulate into the current word.
  defp lex(<<c, rest::binary>>, cur, toks), do: lex(rest, [<<c>> | cur], toks)

  defp flush([], toks), do: toks

  defp flush(cur, toks) do
    [{:word, cur |> Enum.reverse() |> IO.iodata_to_binary()} | toks]
  end

  # Quote / substitution readers. Each returns {raw_including_delimiters, rest}.

  defp read_single(<<?', rest::binary>>, acc), do: {io([acc, ?']), rest}
  defp read_single(<<c, rest::binary>>, acc), do: read_single(rest, [acc, c])
  defp read_single(<<>>, acc), do: {io(acc), ""}

  defp read_double(<<?\\, c, rest::binary>>, acc), do: read_double(rest, [acc, ?\\, c])
  defp read_double(<<?", rest::binary>>, acc), do: {io([acc, ?"]), rest}
  defp read_double(<<c, rest::binary>>, acc), do: read_double(rest, [acc, c])
  defp read_double(<<>>, acc), do: {io(acc), ""}

  defp read_subst(<<?), rest::binary>>, acc, 1), do: {io([acc, ?)]), rest}
  defp read_subst(<<?), rest::binary>>, acc, depth), do: read_subst(rest, [acc, ?)], depth - 1)
  defp read_subst(<<?(, rest::binary>>, acc, depth), do: read_subst(rest, [acc, ?(], depth + 1)
  defp read_subst(<<c, rest::binary>>, acc, depth), do: read_subst(rest, [acc, c], depth)
  defp read_subst(<<>>, acc, _depth), do: {io(acc), ""}

  defp read_brace(<<?}, rest::binary>>, acc), do: {io([acc, ?}]), rest}
  defp read_brace(<<c, rest::binary>>, acc), do: read_brace(rest, [acc, c])
  defp read_brace(<<>>, acc), do: {io(acc), ""}

  defp read_backtick(<<?`, rest::binary>>, acc), do: {io([acc, ?`]), rest}
  defp read_backtick(<<c, rest::binary>>, acc), do: read_backtick(rest, [acc, c])
  defp read_backtick(<<>>, acc), do: {io(acc), ""}

  defp io(iodata), do: IO.iodata_to_binary(iodata)
end
