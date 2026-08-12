defmodule OptimalSystemAgent.OS.Env do
  @moduledoc """
  The single environment scrubber for OS subprocesses.

  A `Port.open/2` or `System.cmd/3` call with no `:env` option hands the child
  the ENTIRE BEAM environment. For a model-authored shell command that means
  `echo $ANTHROPIC_API_KEY` reads the operator's provider credentials straight
  out of the agent's own process. Every spawn that can run untrusted or
  model-authored commands must pass `:env` built here.

  ## How the scrub works

  Erlang's `:env` port option is an OVERLAY, not a replacement: entries are
  merged onto the inherited environment, and `{name, false}` UNSETS a variable.
  So `port_env/1` walks the current environment, decides which names look like
  secrets, and returns exactly those names mapped to `false`. Everything the
  child legitimately needs — `PATH`, `HOME`, `LANG`, `TERM`, `SHELL`, the
  toolchain vars a build depends on, the user's own settings — is untouched.

  A replace-everything allowlist was deliberately rejected: it breaks
  `cargo`/`npm`/`asdf`/`nix` builds in ways that are hard to diagnose, and the
  failure is silent (a build picks a different toolchain rather than erroring).

  ## What counts as a secret

  Two rules, either of which is sufficient:

    * the name contains a secret-shaped fragment (`SECRET`, `TOKEN`,
      `API_KEY`, `PASSWORD`, `CREDENTIAL`, …), or
    * the name starts with a known provider/vendor prefix (`ANTHROPIC_`,
      `OPENAI_`, `OSA_`, …).

  Fragments are chosen to avoid collateral damage: notably `AUTH` alone is NOT
  a fragment, because `SSH_AUTH_SOCK` must survive for `git push` to work.

  ## Configuration

      config :optimal_system_agent,
        env_scrub: [
          enabled: true,              # default true; false disables the scrub
          deny: ["MY_COMPANY_PAT"],   # extra names (exact) or fragments
          allow: ["GITHUB_TOKEN"]     # names kept even if they look secret
        ]

  `allow` always wins over `deny`.
  """

  # Secret-shaped fragments. Matched case-insensitively as substrings of the
  # variable name.
  #
  # Deliberately NOT included, because they produce false positives on vars the
  # toolchain needs: "AUTH" (SSH_AUTH_SOCK), "KEY" alone (KEYBOARD, XKB_*,
  # SSH_KEYSCAN...), "PASS" alone (COMPILER_PASSES, PASSWD_FILE paths).
  @secret_fragments ~w(
    SECRET
    TOKEN
    API_KEY
    APIKEY
    ACCESS_KEY
    PRIVATE_KEY
    SIGNING_KEY
    SESSION_KEY
    ENCRYPTION_KEY
    PASSWORD
    PASSWD
    CREDENTIAL
    AUTH_TOKEN
    BEARER
    CLIENT_SECRET
    REFRESH_TOKEN
  )

  # Vendors whose entire namespace is credential-bearing. Matched as a prefix.
  @secret_prefixes ~w(
    ANTHROPIC_
    OPENAI_
    AZURE_OPENAI_
    GOOGLE_API
    GOOGLE_GENAI
    GEMINI_
    VERTEX_
    GROQ_
    MISTRAL_
    COHERE_
    XAI_
    GROK_
    DEEPSEEK_
    OPENROUTER_
    TOGETHER_
    PERPLEXITY_
    REPLICATE_
    FIREWORKS_
    CEREBRAS_
    MINIMAX_
    MOONSHOT_
    ZHIPU_
    QWEN_
    DASHSCOPE_
    NOUS_
    HUGGINGFACE_
    OSA_
  )

  # Exact names that match none of the shape rules above but are still secrets.
  #
  # Kept deliberately short. Most vendor credentials already match a fragment
  # (`GITHUB_TOKEN` → TOKEN, `AWS_SECRET_ACCESS_KEY` → SECRET/ACCESS_KEY), and
  # every extra entry here is another way to break a legitimate build.
  #
  # NOT included on purpose: `DATABASE_URL` / `REDIS_URL`. They do carry
  # credentials, but they are PROJECT configuration — a scrubbed `DATABASE_URL`
  # silently breaks `mix test`, `prisma migrate`, `rails db:*`. Operators who
  # want them hidden add them to `env_scrub: [deny: [...]]`.
  @secret_names ~w(
    HF_TOKEN
    NETRC
    PGPASSFILE
  )

  @doc """
  Names that are NEVER scrubbed, whatever the rules say. These are the vars a
  shell/build genuinely cannot work without.
  """
  @spec always_keep() :: [String.t()]
  def always_keep do
    ~w(PATH HOME LANG LC_ALL TERM SHELL USER LOGNAME PWD OLDPWD TMPDIR TMP TEMP
       SSH_AUTH_SOCK DISPLAY WAYLAND_DISPLAY XAUTHORITY COMSPEC SYSTEMROOT
       WINDIR PATHEXT COLORTERM TERMINFO TZ)
  end

  @doc """
  `true` when `name` should be hidden from a subprocess.

  Case-insensitive. Configured `allow` entries win over everything.
  """
  @spec secret_name?(String.t()) :: boolean()
  def secret_name?(name) when is_binary(name) do
    upper = String.upcase(name)

    cond do
      upper in Enum.map(allow(), &String.upcase/1) -> false
      upper in always_keep() -> false
      upper in @secret_names -> true
      Enum.any?(extra_deny(), &String.contains?(upper, String.upcase(&1))) -> true
      Enum.any?(@secret_fragments, &String.contains?(upper, &1)) -> true
      Enum.any?(@secret_prefixes, &String.starts_with?(upper, &1)) -> true
      true -> false
    end
  end

  def secret_name?(_), do: false

  @doc """
  The names currently present in this BEAM's environment that would be scrubbed.

  Useful for diagnostics ("what am I hiding from the child?") and for tests.
  """
  @spec secret_names_in_env() :: [String.t()]
  def secret_names_in_env do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&secret_name?/1)
    |> Enum.sort()
  end

  @doc """
  The `:env` option value for `Port.open/2`.

  Returns an overlay charlist list: every secret-shaped name currently set is
  mapped to `false` (unset in the child), followed by `extra` entries the caller
  wants to inject.

  `extra` accepts `{name, value}` pairs with binary or charlist parts, and
  `{name, false}` to force-unset. Caller-supplied entries are applied LAST, so a
  caller can deliberately pass a credential through to a child it trusts.

  When the scrub is disabled by config this still normalizes `extra`, so call
  sites do not need a second code path.
  """
  @spec port_env(keyword() | [{String.t(), String.t() | false}]) :: [
          {charlist(), charlist() | false}
        ]
  def port_env(extra \\ []) do
    scrubbed =
      if enabled?() do
        Enum.map(secret_names_in_env(), fn name -> {to_charlist(name), false} end)
      else
        []
      end

    scrubbed ++ normalize(extra)
  end

  @doc """
  The `:env` option value for `System.cmd/3`, which takes binaries rather than
  charlists and uses `nil` (not `false`) to unset.
  """
  @spec cmd_env(keyword() | [{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def cmd_env(extra \\ []) do
    scrubbed =
      if enabled?(), do: Enum.map(secret_names_in_env(), &{&1, nil}), else: []

    normalized =
      Enum.map(normalize(extra), fn
        {k, false} -> {List.to_string(k), nil}
        {k, v} -> {List.to_string(k), List.to_string(v)}
      end)

    scrubbed ++ normalized
  end

  @doc """
  Extras that re-export `names` from the CURRENT environment, for a child that
  legitimately needs one specific credential.

  A provider CLI is the motivating case: `gh` cannot authenticate without
  `GH_TOKEN`/`GITHUB_TOKEN`, so scrubbing everything would break sign-in — but
  it has no business seeing `ANTHROPIC_API_KEY`. Pass the result as `extra` to
  `cmd_env/1` or `port_env/1`; extras are applied after the scrub, so the named
  vars survive and everything else is still unset.

  Names that are not currently set are returned as `{name, nil}`, which unsets
  them — the same thing the scrub would have done, so absence is not a leak.
  """
  @spec keep([String.t()]) :: [{String.t(), String.t() | nil}]
  def keep(names) when is_list(names) do
    Enum.map(names, fn name -> {name, System.get_env(name)} end)
  end

  @doc """
  Merge a caller-provided `:env` overlay (as accepted by `Port.open/2`) on top of
  the scrub. Existing call sites that already build an env list route through
  here so the scrub is additive rather than a rewrite.
  """
  @spec merge_port_env(term()) :: [{charlist(), charlist() | false}]
  def merge_port_env(env) when is_list(env), do: port_env(env)
  def merge_port_env(_), do: port_env([])

  # ── Private ──────────────────────────────────────────────────────────

  defp normalize(entries) when is_list(entries) do
    Enum.flat_map(entries, fn
      {k, false} -> [{to_charlist(k), false}]
      {k, nil} -> [{to_charlist(k), false}]
      {k, v} -> [{to_charlist(k), to_charlist(v)}]
      _ -> []
    end)
  end

  defp normalize(_), do: []

  defp config, do: Application.get_env(:optimal_system_agent, :env_scrub, [])

  defp enabled?, do: Keyword.get(config(), :enabled, true) != false

  defp extra_deny, do: config() |> Keyword.get(:deny, []) |> Enum.filter(&is_binary/1)

  defp allow, do: config() |> Keyword.get(:allow, []) |> Enum.filter(&is_binary/1)
end
