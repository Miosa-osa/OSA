defmodule OptimalSystemAgent.Channels.HTTP.API.CostRoutes do
  @moduledoc """
  Cost and budget routes for the OSA HTTP API.

  Forwarded prefix: /cost

  Effective routes:
    GET  /              → Cost summary (totals from Budget GenServer)
    GET  /by-agent      → Costs grouped by agent (stub — per-agent tracking pending)
    GET  /by-model      → Costs grouped by model (stub — per-model tracking pending)
    GET  /events        → Recent cost events, paginated
    GET  /budgets       → Budget limits from ~/.osa/config.json
    PUT  /budgets/:name → Set budget limit for an agent
  """

  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET / — cost summary ────────────────────────────────────────────

  get "/" do
    status = fetch_budget_status()

    # Budget tracks daily_spent / monthly_spent in USD.
    # Derive total_cost_usd from monthly spend (best available aggregate).
    # Token counts are not tracked by the current Budget GenServer — return 0
    # until a token-aware ledger is added.
    total_cost_usd = Map.get(status, :monthly_spent, 0.0)
    ledger_entries = Map.get(status, :ledger_entries, 0)

    since =
      Date.utc_today()
      |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
      |> DateTime.to_iso8601()

    json(conn, 200, %{
      total_tokens: 0,
      total_cost_usd: round6(total_cost_usd),
      input_tokens: 0,
      output_tokens: 0,
      sessions: ledger_entries,
      since: since
    })
  end

  # ── GET /by-agent — per-agent cost breakdown ────────────────────────

  get "/by-agent" do
    ledger = fetch_ledger()

    agents =
      ledger
      |> Enum.group_by(fn e -> e[:session_id] || "unknown" end)
      |> Enum.map(fn {session, entries} ->
        %{
          agent: session,
          cost_usd: entries |> Enum.map(&(&1[:cost_usd] || 0)) |> Enum.sum() |> round6(),
          requests: length(entries),
          tokens_in: entries |> Enum.map(&(&1[:tokens_in] || 0)) |> Enum.sum(),
          tokens_out: entries |> Enum.map(&(&1[:tokens_out] || 0)) |> Enum.sum()
        }
      end)
      |> Enum.sort_by(& &1.cost_usd, :desc)

    json(conn, 200, %{agents: agents})
  end

  # ── GET /by-model — per-model cost breakdown ────────────────────────

  get "/by-model" do
    ledger = fetch_ledger()

    models =
      ledger
      |> Enum.group_by(fn e -> e[:model] || "unknown" end)
      |> Enum.map(fn {model, entries} ->
        %{
          model: model,
          provider: (List.first(entries) || %{})[:provider] || "unknown",
          cost_usd: entries |> Enum.map(&(&1[:cost_usd] || 0)) |> Enum.sum() |> round6(),
          requests: length(entries),
          tokens_in: entries |> Enum.map(&(&1[:tokens_in] || 0)) |> Enum.sum(),
          tokens_out: entries |> Enum.map(&(&1[:tokens_out] || 0)) |> Enum.sum()
        }
      end)
      |> Enum.sort_by(& &1.cost_usd, :desc)

    json(conn, 200, %{models: models})
  end

  # ── GET /events — paginated cost events ─────────────────────────────

  get "/events" do
    {page, per_page} = pagination_params(conn)
    ledger = fetch_ledger()
    total = length(ledger)
    offset = (page - 1) * per_page

    events =
      ledger
      |> Enum.drop(offset)
      |> Enum.take(per_page)
      |> Enum.map(fn e ->
        %{
          id: e[:id],
          timestamp: if(e[:timestamp], do: DateTime.to_iso8601(e[:timestamp])),
          provider: e[:provider],
          model: e[:model],
          tokens_in: e[:tokens_in],
          tokens_out: e[:tokens_out],
          cost_usd: e[:cost_usd],
          session_id: e[:session_id]
        }
      end)

    json(conn, 200, %{events: events, count: total, page: page, per_page: per_page})
  end

  # ── GET /budgets — read budget limits from config file ───────────────

  get "/budgets" do
    config = read_config()
    budgets = Map.get(config, "budgets", %{})

    # Merge in the live limits from the Budget GenServer for the global budget.
    status = fetch_budget_status()

    global =
      Map.get(budgets, "global", %{})
      |> Map.put_new("daily_limit_usd", Map.get(status, :daily_limit))
      |> Map.put_new("monthly_limit_usd", Map.get(status, :monthly_limit))

    json(conn, 200, %{
      budgets: Map.put(budgets, "global", global)
    })
  end

  # ── PUT /budgets/:agent_name — set budget limit for an agent ─────────

  put "/budgets/:agent_name" do
    try do
      params = conn.body_params

      if not is_map(params) or params == %{} do
        json_error(conn, 400, "invalid_request", "Request body must be a non-empty JSON object")
      else
        allowed = ~w(daily_limit_usd daily_limit_tokens monthly_limit_usd monthly_limit_tokens)
        limit_params = Map.take(params, allowed)

        if map_size(limit_params) == 0 do
          json_error(conn, 400, "invalid_request", "No valid budget fields provided")
        else
          with :ok <- validate_limit_values(limit_params),
               :ok <- persist_agent_budget(agent_name, limit_params) do
            json(conn, 200, %{
              agent: agent_name,
              limits: limit_params
            })
          else
            {:error, :invalid_values} ->
              json_error(
                conn,
                400,
                "invalid_request",
                "Budget limit values must be non-negative numbers"
              )

            {:error, :write_failed} ->
              json_error(conn, 500, "internal_error", "Failed to persist budget configuration")
          end
        end
      end
    rescue
      _ -> json_error(conn, 500, "internal_error", "Failed to set budget limit")
    end
  end

  # ── catch-all ────────────────────────────────────────────────────────

  match _ do
    json_error(conn, 404, "not_found", "Cost endpoint not found")
  end

  # ── Private helpers ──────────────────────────────────────────────────

  # Round a money amount to 6 dp. Coerces via `/ 1` first so an integer input
  # (e.g. a zero sum from `Enum.sum/1` over integer/absent cost fields, or an
  # integer `monthly_spent` from the Budget GenServer) does not raise
  # ArgumentError — `Float.round/2` requires a float.
  defp round6(n) when is_number(n), do: Float.round(n / 1, 6)
  defp round6(_), do: 0.0

  defp fetch_ledger do
    case OptimalSystemAgent.Agent.Budget.get_ledger() do
      {:ok, ledger} when is_list(ledger) -> ledger
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp fetch_budget_status do
    case OptimalSystemAgent.Budget.get_status() do
      {:ok, status} -> status
      status when is_map(status) -> status
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp config_path do
    Application.get_env(:optimal_system_agent, :bootstrap_dir, "~/.osa")
    |> Path.expand()
    |> Path.join("config.json")
  end

  defp read_config do
    path = config_path()

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content),
         true <- is_map(parsed) do
      parsed
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp write_config(config) do
    path = config_path()
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        File.write!(path, json)
        :ok

      {:error, reason} ->
        Logger.warning("[CostRoutes] Failed to encode config: #{inspect(reason)}")
        {:error, :write_failed}
    end
  rescue
    e ->
      Logger.warning("[CostRoutes] Config write error: #{Exception.message(e)}")
      {:error, :write_failed}
  end

  defp validate_limit_values(params) do
    numeric_keys = ~w(daily_limit_usd daily_limit_tokens monthly_limit_usd monthly_limit_tokens)

    valid? =
      Enum.all?(numeric_keys, fn key ->
        case Map.get(params, key) do
          nil -> true
          v when is_number(v) -> v >= 0
          _ -> false
        end
      end)

    if valid?, do: :ok, else: {:error, :invalid_values}
  end

  defp persist_agent_budget(agent_name, limit_params) do
    existing = read_config()
    budgets = Map.get(existing, "budgets", %{})
    agent_budget = Map.get(budgets, agent_name, %{})

    updated_agent_budget = Map.merge(agent_budget, limit_params)
    updated_budgets = Map.put(budgets, agent_name, updated_agent_budget)
    updated_config = Map.put(existing, "budgets", updated_budgets)

    write_config(updated_config)
  end
end
