defmodule OptimalSystemAgent.Usage do
  @moduledoc """
  What your account has left, and what this session has spent — kept apart.

  ## The one rule this module exists to enforce

  There are two completely different numbers a user might mean by "usage", and
  conflating them is worse than showing neither:

    * **The provider's report** — what the vendor says about *your account*:
      the plan you are on, the percentage of a rate-limit window you have
      consumed, when that window rolls. OSA does not compute these. It repeats
      them, with the time they were observed.

    * **OSA's own measurement** — tokens and USD OSA counted while running
      your turns. This is a floor, not a bill: it does not know about work you
      did in another tool, it prices API-key providers from a static table, and
      for a subscription there is no per-token bill for it to be a floor of.

  Every row is therefore rendered under one of those two headings, never
  blended into a single "usage" figure.

  ## Never fabricate

  A provider that exposes no quota API gets `:not_reported`. A provider whose
  quota can only be read by spending a metered request gets `:withheld`, with
  the reason stated — GitHub Copilot is the live example: burning a premium
  request in order to display how many premium requests remain is a bad trade
  and OSA refuses to make it. Neither renders as `0`, because a zero on a quota
  screen reads as "you have none left".

  ## Read-only contract

  `report/1` performs no network I/O by default and can never spend a metered
  request. It is safe on a status screen, in a loop. Passing `probe: true`
  enables only probes that are free and local — today that is the Ollama
  daemon on the loopback interface, which answers `/api/me` for nothing.
  """

  alias OptimalSystemAgent.Agent.Loop
  alias OptimalSystemAgent.Auth.Subscription
  alias OptimalSystemAgent.Budget
  alias OptimalSystemAgent.Runtime.Identity
  alias OptimalSystemAgent.Usage.RateLimits

  @type account_status :: :reported | :not_reported | :withheld | :not_connected | :awaiting

  @type entry :: %{
          provider: String.t(),
          display_name: String.t(),
          active?: boolean(),
          auth_mode: :subscription | :external_cli | :api_key | :none,
          account: map(),
          measured: map() | nil
        }

  @doc """
  Build the usage report.

  ## Options

    * `:session_id` — scope OSA's own measurement to this session.
    * `:all` — include every configured provider, not just the active one.
    * `:probe` — allow free, local probes (Ollama's loopback daemon). Never
      enables anything metered.
  """
  @spec report(keyword()) :: %{active: String.t() | nil, entries: [entry()]}
  def report(opts \\ []) do
    active = active_provider_id()
    all? = Keyword.get(opts, :all, false)

    ids =
      if all? do
        Enum.uniq(Enum.reject([active | configured_provider_ids()], &is_nil/1))
      else
        Enum.reject([active], &is_nil/1)
      end

    %{active: active, entries: Enum.map(ids, &entry(&1, active, opts))}
  end

  # ── One provider ────────────────────────────────────────────────────────

  defp entry(id, active, opts) do
    %{
      provider: id,
      display_name: display_name(id),
      active?: id == active,
      auth_mode: auth_mode(id),
      account: account_report(id, opts),
      measured: measured(id, active, opts)
    }
  end

  # OSA only counts what OSA ran. Attributing this session's tokens to a
  # provider that is not the one that ran them would be a fabrication, so the
  # measurement is attached to the active provider and to nothing else.
  defp measured(id, active, opts) when id == active do
    case Keyword.get(opts, :session_id) do
      sid when is_binary(sid) and sid != "" -> session_spend(sid, id)
      _ -> nil
    end
  end

  defp measured(_id, _active, _opts), do: nil

  defp session_spend(session_id, provider_id) do
    spend =
      case Loop.get_state(session_id) do
        {:ok, state} -> state[:spend]
        _ -> nil
      end

    spend = spend || OptimalSystemAgent.Agent.SessionPersistence.load_spend(session_id)

    %{
      session_id: session_id,
      input_tokens: num(spend[:input_tokens]),
      output_tokens: num(spend[:output_tokens]),
      cache_read_tokens: num(spend[:cache_read_tokens]),
      cache_creation_tokens: num(spend[:cache_creation_tokens]),
      # A priced figure is only meaningful where OSA holds a real per-token
      # rate. For a subscription there is no per-token bill at all, and for a
      # provider with no rate table the number would be a guess wearing a
      # dollar sign.
      cost_usd: if(priced?(provider_id), do: num(spend[:cost_usd]), else: nil),
      cost_note: cost_note(provider_id)
    }
  rescue
    _ -> nil
  end

  defp priced?(provider_id) do
    auth_mode(provider_id) == :api_key and Budget.has_usd_pricing?(provider_id)
  end

  defp cost_note(provider_id) do
    case auth_mode(provider_id) do
      :api_key ->
        if Budget.has_usd_pricing?(provider_id),
          do: nil,
          else: "no per-token rate for this provider — tokens shown, cost not priced"

      _ ->
        "billed to your plan, not per token — no USD figure applies"
    end
  end

  # ── The provider's own report ───────────────────────────────────────────

  defp account_report("openai_codex" = id, _opts) do
    case Subscription.status(id) do
      %{connected?: false} ->
        not_connected(id)

      status ->
        base = [{"Plan", status[:plan]}]

        case RateLimits.get(id) do
          nil ->
            reported(base,
              status: :awaiting,
              note:
                "Plan quota is only reported on inference responses " <>
                  "(x-codex-* headers). None seen yet — it appears after the next request."
            )

          obs ->
            reported(
              base ++
                [
                  {"Window used", percent(obs[:used_percent])},
                  {"Window", window_label(obs[:window_minutes])},
                  {"Resets", obs[:resets_at]},
                  {"Limit", obs[:limit_name]},
                  {"Observed", age(obs[:observed_at])}
                ],
              note: "Reported by OpenAI on the last response — a measurement with an age."
            )
        end
    end
  end

  defp account_report("copilot_cli" = id, _opts), do: copilot_account(id)
  defp account_report("copilot" = id, _opts), do: copilot_account(id)

  defp account_report("claude_cli" = id, _opts) do
    case Subscription.status(id) do
      %{connected?: false} ->
        not_connected(id)

      status ->
        reported([{"Plan", status[:plan]}, {"Account", status[:account]}],
          status: :not_reported,
          note:
            "Anthropic exposes no remaining-quota API to OSA. Per-turn cost and " <>
              "tokens below are OSA's own count of what it ran."
        )
    end
  end

  # Both Ollama entries share this. The local provider is not only local: a
  # `…:cloud` model name is relayed by the same daemon to ollama.com under the
  # signed-in account, so the plan is exactly as relevant there.
  defp account_report(id, opts) when id in ["ollama_cloud", "ollama", "ollama_local"] do
    if Keyword.get(opts, :probe, false) do
      case ollama_account() do
        {:ok, me} ->
          reported([{"Plan", me["plan"]}, {"Account", me["email"] || me["name"]}],
            note:
              "Reported by the local Ollama daemon, which is signed in to your " <>
                "ollama.com account. No remaining-quota figure is exposed."
          )

        {:error, reason} ->
          %{
            status: :not_reported,
            fields: [],
            note: ollama_reason(reason),
            provider: id
          }
      end
    else
      %{
        status: :not_reported,
        fields: [],
        note: "Account plan is read from the local Ollama daemon; not probed in this view.",
        provider: id
      }
    end
  end

  defp account_report(id, _opts) do
    %{
      status: :not_reported,
      fields: [],
      note:
        "This provider is used with an API key and reports no account balance " <>
          "or quota to OSA. Check your spend in the provider's own dashboard.",
      provider: id
    }
  end

  # Copilot's premium-request balance is the number a user actually wants, and
  # every route to it that OSA has costs a premium request. Displaying quota by
  # consuming quota is a bad trade, so this refuses and says why rather than
  # showing a figure it had to pay for — or worse, a zero.
  defp copilot_account(id) do
    case Subscription.status(id) do
      %{connected?: false} ->
        not_connected(id)

      status ->
        reported([{"Plan", status[:plan]}, {"Account", status[:account]}],
          status: :withheld,
          note:
            "Premium-request balance is not readable for free — the only way OSA " <>
              "could show it is to spend a metered premium request. See " <>
              "github.com/settings/copilot for the real figure."
        )
    end
  end

  defp not_connected(id) do
    %{
      status: :not_connected,
      fields: [],
      note: "Not connected. Sign in with `osa auth login #{id}`.",
      provider: id
    }
  end

  defp reported(fields, opts) do
    %{
      status: Keyword.get(opts, :status, :reported),
      fields: Enum.reject(fields, fn {_l, v} -> is_nil(v) or v == "" end),
      note: Keyword.get(opts, :note)
    }
  end

  # ── Free local probe: the Ollama daemon ─────────────────────────────────

  # `ollama signin` does not mint a token OSA could read: it registers the
  # machine's Ed25519 key (`~/.ollama/id_ed25519`) with an ollama.com account,
  # and the daemon signs its own cloud requests with it. The daemon then
  # answers `POST /api/me` on loopback, unauthenticated and free, with the
  # account and plan. That is the only account fact available here, and it
  # costs nothing to ask for.
  # `:httpc` rather than `Req`: `osa usage` runs under `mix run --no-start`,
  # where Req's Finch pool does not exist. A loopback GET needs no pool and no
  # TLS, and a status command that only works inside the daemon is half a
  # command.
  # Public (`@doc false`) for exactly one caller:
  # `Auth.Providers.OllamaAccount`, which needs the same answer to decide
  # whether the account auth mode is connected. Two probes of one endpoint
  # would eventually disagree about what "signed in" means, so there is one.
  # `base` is optional so that caller can pass the daemon URL it resolved
  # (which also honours a loopback `:ollama_url`); `nil` keeps this command's
  # own resolution byte-for-byte unchanged.
  @doc false
  @spec ollama_account(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def ollama_account(base \\ nil) do
    base = base || System.get_env("OLLAMA_HOST") || "http://127.0.0.1:11434"
    base = if String.starts_with?(base, "http"), do: base, else: "http://" <> base

    with {:ok, host, port} <- loopback_target(base),
         {:ok, status, body} <- tcp_post(host, port, "/api/me") do
      case status do
        200 ->
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> {:ok, map}
            _ -> {:error, :daemon_unreachable}
          end

        401 ->
          {:error, :signed_out}

        other ->
          {:error, {:http, other}}
      end
    end
  rescue
    _ -> {:error, :daemon_unreachable}
  catch
    _, _ -> {:error, :daemon_unreachable}
  end

  # Only a plaintext loopback host is ever contacted. A remote or https
  # `OLLAMA_HOST` is declined rather than dialled: this is a status screen, and
  # reaching out to an arbitrary host to draw one is not something a status
  # screen should do.
  defp loopback_target(base) do
    case URI.parse(base) do
      %URI{scheme: "http", host: h, port: p}
      when h in ["127.0.0.1", "localhost", "0.0.0.0", "::1"] and is_integer(p) ->
        {:ok, String.to_charlist(h), p}

      _ ->
        {:error, :daemon_unreachable}
    end
  end

  defp tcp_post(host, port, path) do
    opts = [:binary, active: false, packet: :raw]

    case :gen_tcp.connect(host, port, opts, 1_000) do
      {:ok, sock} ->
        try do
          req =
            "POST #{path} HTTP/1.1\r\nHost: #{host}:#{port}\r\n" <>
              "Accept: application/json\r\nContent-Type: application/json\r\n" <>
              "Content-Length: 2\r\nConnection: close\r\n\r\n{}"

          :ok = :gen_tcp.send(sock, req)
          parse_http(recv_all(sock, ""))
        after
          :gen_tcp.close(sock)
        end

      _ ->
        {:error, :daemon_unreachable}
    end
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 1_500) do
      {:ok, data} -> recv_all(sock, acc <> data)
      _ -> acc
    end
  end

  defp parse_http(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [head, body] ->
        case Regex.run(~r/^HTTP\/1\.\d (\d{3})/, head) do
          [_, code] -> {:ok, String.to_integer(code), strip_chunking(body)}
          _ -> {:error, :daemon_unreachable}
        end

      _ ->
        {:error, :daemon_unreachable}
    end
  end

  # The daemon answers this endpoint with a small chunked body. Only the first
  # chunk is ever needed, and a malformed one falls through to the JSON decode
  # failing, which is reported as "could not read" rather than guessed at.
  defp strip_chunking(body) do
    trimmed = String.trim(body)

    case Regex.run(~r/\{.*\}/s, trimmed) do
      [json] -> json
      _ -> trimmed
    end
  end

  defp ollama_reason(:signed_out),
    do: "The local Ollama daemon is not signed in to an account. Run `ollama signin`."

  defp ollama_reason(:daemon_unreachable),
    do: "No local Ollama daemon answered, so no account plan could be read."

  defp ollama_reason({:http, status}),
    do: "The local Ollama daemon answered HTTP #{status}; no account plan could be read."

  # ── Provider metadata ───────────────────────────────────────────────────

  @doc "The active provider id as a string, or `nil`."
  @spec active_provider_id() :: String.t() | nil
  def active_provider_id do
    case Identity.provider() do
      nil -> nil
      p -> to_string(p)
    end
  rescue
    _ -> nil
  end

  @doc """
  Provider ids worth showing in the `--all` view.

  Deliberately does **not** delegate to `Registry.provider_configured?/1`:
  that probes the network for Ollama, and a status screen must not be able to
  hang or to make a request. Configuration here means a credential is present,
  which is a pure read and true in `osa usage` where no OTP tree is running.
  """
  @spec configured_provider_ids() :: [String.t()]
  def configured_provider_ids do
    connected = for s <- safe_status_all(), s.connected?, do: to_string(s.provider)

    keyed =
      OptimalSystemAgent.Providers.Registry.list_providers()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&key_present?/1)

    Enum.uniq(connected ++ keyed) |> Enum.sort()
  rescue
    _ -> []
  end

  defp safe_status_all do
    Subscription.status_all()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp key_present?(id) do
    present?(app_env_key(id)) or present?(System.get_env(String.upcase(id) <> "_API_KEY"))
  end

  # `to_existing_atom` raising for a provider that has never had a config key
  # read is the normal case, not an error — it just means no app-env value can
  # exist for it, so the env var is the only source left to check.
  defp app_env_key(id) do
    Application.get_env(:optimal_system_agent, String.to_existing_atom("#{id}_api_key"))
  rescue
    _ -> nil
  end

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(_), do: false

  @doc "How this provider is authenticated."
  @spec auth_mode(String.t()) :: :subscription | :external_cli | :api_key | :none
  def auth_mode(id) do
    cond do
      id in ["claude_cli", "copilot_cli"] -> :external_cli
      Subscription.supported?(id) -> :subscription
      true -> :api_key
    end
  rescue
    _ -> :api_key
  end

  defp display_name(id) do
    case Subscription.impl(id) do
      nil -> id |> String.replace("_", " ")
      mod -> safe_display_name(mod, id)
    end
  end

  defp safe_display_name(mod, id) do
    mod.display_name()
  rescue
    _ -> id
  end

  # ── Formatting helpers ──────────────────────────────────────────────────

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp percent(p) when is_number(p), do: "#{round(p)}%"
  defp percent(_), do: nil

  defp window_label(m) when is_number(m) and m >= 1440, do: "#{round(m / 1440)}d"
  defp window_label(m) when is_number(m) and m >= 60, do: "#{round(m / 60)}h"
  defp window_label(m) when is_number(m), do: "#{round(m)}m"
  defp window_label(_), do: nil

  @doc "Human age of a unix timestamp, e.g. `3m ago`. `nil` when unknown."
  @spec age(integer() | nil) :: String.t() | nil
  def age(at) when is_integer(at) do
    case System.system_time(:second) - at do
      s when s < 0 -> "just now"
      s when s < 60 -> "#{s}s ago"
      s when s < 3600 -> "#{div(s, 60)}m ago"
      s when s < 86_400 -> "#{div(s, 3600)}h ago"
      s -> "#{div(s, 86_400)}d ago"
    end
  end

  def age(_), do: nil
end
