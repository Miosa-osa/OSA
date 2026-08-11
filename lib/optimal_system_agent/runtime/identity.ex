defmodule OptimalSystemAgent.Runtime.Identity do
  @moduledoc """
  OSA's answer to "what model are you?" — resolved from runtime state, never
  guessed from a config file.

  ## Why this module exists

  Asked which model it was running, OSA could not answer. It grepped
  `~/.osa/config.json`, guessed wrong, and persisted the guess to memory as a
  fact — all while the TUI status bar was displaying the correct model the
  entire time. The status bar was right because it reads `GET /health`, which
  reads the reconciled application environment. The agent was wrong because it
  read one of the three config files that *feed* that reconciliation.

  So: this module is the ONE place that resolves the active identity, and every
  surface that displays it calls here.

    * `GET /health` (`Channels.HTTP`) → the TUI status bar / header / sidebar
    * `Agent.Context` runtime block → what the model itself can see
    * `CLI.Doctor` → `osa doctor`

  Because they share this implementation they cannot silently disagree; the
  answer the agent gives is by construction the same string on the status bar.

  ## Resolution

  `model/0` and `provider/0` mirror `/health` exactly: the reconciled
  `:default_model` / `:default_provider` application env, written once at boot
  by `Application.reconcile_model_config/0` and rewritten by `/switch`. A nil
  model falls back to the provider catalog's default, then to the provider name.

  Per-session overrides (`Loop.swap_provider/3`) live on the Loop struct, not in
  app env, so callers holding Loop state should pass it to `resolve/1` — the
  session's own model wins, and the global default is the fallback.

  ## Source attribution

  `model_source/0` reports WHICH input won, so a user staring at three files
  that disagree does not have to reverse-engineer the precedence chain. See
  `OptimalSystemAgent.Application` (the reconciliation) for the chain itself;
  this module re-evaluates the same inputs in the same order for reporting only
  and never changes what wins.
  """

  alias OptimalSystemAgent.ConfigFile
  alias OptimalSystemAgent.Providers.Registry

  @app :optimal_system_agent

  @typedoc "Which input supplied the effective model."
  @type source ::
          :session_override
          | :config_toml
          | :config_json
          | :env
          | :app_env
          | :catalog_default
          | :unknown

  @doc """
  The active provider as an atom, or `nil` when unresolvable.
  """
  @spec provider() :: atom() | nil
  def provider do
    case Application.get_env(@app, :default_provider) do
      nil -> nil
      p when is_atom(p) -> p
      p when is_binary(p) -> provider_atom(p)
      _ -> nil
    end
  end

  @doc """
  The active model id, resolved exactly the way `GET /health` resolves it.

  Never returns nil: degrades to the provider catalog default, then to the
  provider name, then to `"unknown"`.
  """
  @spec model() :: String.t()
  def model do
    case Application.get_env(@app, :default_model) do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        prov = Application.get_env(@app, :default_provider, :ollama)

        case safe(fn -> Registry.provider_info(prov) end) do
          {:ok, info} -> to_string(info.default_model)
          _ -> to_string(prov)
        end
    end
  end

  @doc """
  Provider base URL with any credential stripped.

  Read from the same env var the provider itself dials, so it reflects where
  requests actually go (e.g. `https://ollama.com` for `:cloud` models).
  """
  @spec base_url() :: String.t() | nil
  def base_url, do: base_url(provider())

  @spec base_url(atom() | nil) :: String.t() | nil
  def base_url(nil), do: nil

  def base_url(prov) do
    var =
      case prov do
        :ollama -> "OLLAMA_URL"
        :anthropic -> "ANTHROPIC_BASE_URL"
        :openai -> "OPENAI_BASE_URL"
        :groq -> "GROQ_BASE_URL"
        :openrouter -> "OPENROUTER_BASE_URL"
        :miosa -> "MIOSA_BASE_URL"
        _ -> nil
      end

    case var && System.get_env(var) do
      url when is_binary(url) and url != "" -> redact(url)
      _ -> default_base_url(prov)
    end
  end

  defp default_base_url(:ollama), do: "http://localhost:11434"
  defp default_base_url(_), do: nil

  # Strip userinfo (https://key@host) and any api_key/token query param so a
  # base URL is always safe to print in a prompt, a log, or a doctor report.
  defp redact(url) do
    url
    |> String.replace(~r{//[^/@\s]+@}, "//<redacted>@")
    |> String.replace(
      ~r{([?&](?:api_?key|token|access_token|password)=)[^&\s]+}i,
      "\\1<redacted>"
    )
  end

  @doc "OSA's own version — the same value `/health` reports to the TUI."
  @spec version() :: String.t()
  def version do
    case safe(fn -> OptimalSystemAgent.ReleaseNotes.current_version() end) do
      v when is_binary(v) and v != "" -> v
      _ -> "unknown"
    end
  end

  @doc """
  Effective context window for the active model: `{:ok, tokens}` or `:unknown`.

  Delegates to `Registry.effective_context_window_info/2`, the honest variant
  that says `:unknown` rather than inventing the 128k config default. Same call
  `/health` makes, so the number here and the TUI's "N% ctx" meter agree.
  """
  @spec context_window() :: {:ok, pos_integer()} | :unknown
  def context_window, do: context_window(model(), provider())

  @spec context_window(String.t() | nil, atom() | nil) :: {:ok, pos_integer()} | :unknown
  def context_window(model, prov) do
    case safe(fn -> Registry.effective_context_window_info(model, prov) end) do
      {:ok, cw} when is_integer(cw) -> {:ok, cw}
      _ -> :unknown
    end
  end

  @doc """
  Where the effective model came from, as `{source, human_label}`.

  Re-evaluates the same inputs `Application.reconcile_model_config/0` consults,
  in the same order, purely to attribute the winner. Reporting only — it can
  never change which value wins.
  """
  @spec model_source() :: {source(), String.t()}
  def model_source do
    effective = model()

    toml = safe_config(fn -> ConfigFile.toml_model_section() end, %{})
    toml_model = is_map(toml) && Map.get(toml, "model")
    json_model = safe_config(fn -> json_model() end, nil)
    env_model = System.get_env("OLLAMA_MODEL")

    cond do
      match_str?(toml_model, effective) -> {:config_toml, "~/.osa/config.toml [model].model"}
      match_str?(json_model, effective) -> {:config_json, "~/.osa/config.json \"model\""}
      match_str?(env_model, effective) -> {:env, "OLLAMA_MODEL env (~/.osa/.env)"}
      Application.get_env(@app, :default_model) -> {:app_env, "application config"}
      true -> {:catalog_default, "provider catalog default"}
    end
  end

  # config.json read directly rather than through the merged ConfigFile view,
  # because the merged view cannot tell json and toml apart — which is exactly
  # the distinction being reported.
  defp json_model do
    with true <- File.exists?(ConfigFile.json_path()),
         {:ok, raw} <- File.read(ConfigFile.json_path()),
         {:ok, %{"model" => m}} when is_binary(m) <- Jason.decode(raw) do
      m
    else
      _ -> nil
    end
  end

  defp match_str?(a, b) when is_binary(a) and is_binary(b), do: a != "" and a == b
  defp match_str?(_, _), do: false

  @doc """
  Resolve identity for a Loop state (or any map/keyword carrying
  `:provider` / `:model`). A live session override wins over the global default;
  anything missing falls back to the global values.
  """
  @spec resolve(map() | keyword() | nil) :: %{
          model: String.t(),
          provider: atom() | nil,
          overridden?: boolean()
        }
  def resolve(state \\ nil) do
    session_model = fetch(state, :model)
    session_provider = fetch(state, :provider)

    %{
      model:
        if(is_binary(session_model) and session_model != "", do: session_model, else: model()),
      provider: session_provider || provider(),
      overridden?: is_binary(session_model) and session_model != ""
    }
  end

  defp fetch(nil, _), do: nil
  defp fetch(state, key) when is_map(state), do: Map.get(state, key)

  defp fetch(state, key) when is_list(state) do
    if Keyword.keyword?(state), do: Keyword.get(state, key), else: nil
  end

  defp fetch(_, _), do: nil

  @doc """
  One line, for injection into the agent's own context.

  Deliberately terse: this rides in the budget-critical `runtime` block, so it
  buys the agent a correct, instant answer to "what model are you / what version
  / how much context do I have" for well under a hundred bytes — versus the
  three tool calls and two wrong guesses it costs to discover the same facts.
  """
  @spec context_line(map() | keyword() | nil) :: String.t()
  def context_line(state \\ nil) do
    %{model: m, provider: p} = resolve(state)

    ctx =
      case context_window(m, p) do
        {:ok, cw} -> ", ctx #{cw}"
        :unknown -> ""
      end

    "- Model: #{m} (provider #{p || "unknown"}#{ctx}) | OSA v#{version()}"
  end

  @doc """
  Full human-readable identity, including the source attribution that makes a
  three-file precedence chain debuggable. Used by `osa doctor`.
  """
  @spec describe() :: %{
          model: String.t(),
          provider: atom() | nil,
          base_url: String.t() | nil,
          version: String.t(),
          context_window: pos_integer() | nil,
          source: source(),
          source_label: String.t()
        }
  def describe do
    m = model()
    p = provider()
    {src, label} = model_source()

    %{
      model: m,
      provider: p,
      base_url: base_url(p),
      version: version(),
      context_window:
        case context_window(m, p) do
          {:ok, cw} -> cw
          :unknown -> nil
        end,
      source: src,
      source_label: label
    }
  end

  # Every lookup here crosses into the provider Registry / config layer, which
  # may be unstarted (doctor runs from a cold VM) or mid-restart. Identity must
  # degrade, never raise: a prompt block that crashes is worse than a missing
  # context window.
  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp safe_config(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp provider_atom(name) when is_binary(name) do
    Enum.find(Registry.list_providers(), &(Atom.to_string(&1) == name))
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
