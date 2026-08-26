defmodule OptimalSystemAgent.Channels.HTTP.API.KnowledgeRoutes do
  @moduledoc """
  Knowledge graph routes forwarded from /api/v1/knowledge.

  Effective routes:
    GET  /triples            Query triples (subject/predicate/object filters)
    POST /assert             Assert a triple
    POST /retract            Retract a triple
    POST /sparql             Execute a SPARQL query
    POST /reason             Run OWL 2 RL reasoner (materialize)
    GET  /context/:agent_id  Get agent context injection
    GET  /count              Triple count
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  plug(:match)
  plug(:dispatch)

  # ── GET /triples — query triples ───────────────────────────────────
  # Query params: subject, predicate, object (all optional).

  get "/triples" do
    ensure_store_started()

    pattern =
      []
      |> maybe_pattern(:subject, conn.query_params["subject"])
      |> maybe_pattern(:predicate, conn.query_params["predicate"])
      |> maybe_pattern(:object, conn.query_params["object"])

    case MiosaKnowledge.query(store(), pattern) do
      {:ok, triples} ->
        encoded = Enum.map(triples, fn {s, p, o} -> %{subject: s, predicate: p, object: o} end)
        body = Jason.encode!(%{triples: encoded, count: length(encoded)})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        Logger.error("[Knowledge] query failed: #{inspect(reason)}")
        json_error(conn, 500, "query_failed", inspect(reason))
    end
  end

  # ── POST /assert — assert a triple ─────────────────────────────────

  post "/assert" do
    ensure_store_started()

    with %{"subject" => s, "predicate" => p, "object" => o} <- conn.body_params,
         true <- is_binary(s) and s != "",
         true <- is_binary(p) and p != "",
         true <- is_binary(o) and o != "" do
      case MiosaKnowledge.assert(store(), {s, p, o}) do
        :ok ->
          body = Jason.encode!(%{status: "asserted", subject: s, predicate: p, object: o})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, body)

        {:error, reason} ->
          Logger.error("[Knowledge] assert failed: #{inspect(reason)}")
          json_error(conn, 500, "assert_failed", inspect(reason))
      end
    else
      _ ->
        json_error(
          conn,
          400,
          "invalid_request",
          "Required fields: subject, predicate, object (non-empty strings)"
        )
    end
  end

  # ── POST /retract — retract a triple ───────────────────────────────

  post "/retract" do
    ensure_store_started()

    with %{"subject" => s, "predicate" => p, "object" => o} <- conn.body_params,
         true <- is_binary(s) and s != "",
         true <- is_binary(p) and p != "",
         true <- is_binary(o) and o != "" do
      case MiosaKnowledge.retract(store(), {s, p, o}) do
        :ok ->
          body = Jason.encode!(%{status: "retracted", subject: s, predicate: p, object: o})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, reason} ->
          Logger.error("[Knowledge] retract failed: #{inspect(reason)}")
          json_error(conn, 500, "retract_failed", inspect(reason))
      end
    else
      _ ->
        json_error(
          conn,
          400,
          "invalid_request",
          "Required fields: subject, predicate, object (non-empty strings)"
        )
    end
  end

  # ── POST /sparql — execute SPARQL query ────────────────────────────

  post "/sparql" do
    ensure_store_started()

    with %{"query" => sparql_query} <- conn.body_params,
         true <- is_binary(sparql_query) and sparql_query != "" do
      case MiosaKnowledge.sparql(store(), sparql_query) do
        {:ok, results} ->
          body = Jason.encode!(%{results: results, count: length(results)})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, body)

        {:error, reason} ->
          Logger.error("[Knowledge] SPARQL failed: #{inspect(reason)}")
          json_error(conn, 400, "sparql_failed", inspect(reason))
      end
    else
      _ ->
        json_error(
          conn,
          400,
          "invalid_request",
          "Required field: query (non-empty SPARQL string)"
        )
    end
  end

  # ── POST /reason — run OWL 2 RL reasoner ──────────────────────────

  post "/reason" do
    ensure_store_started()

    case MiosaKnowledge.Reasoner.materialize(store(), []) do
      {:ok, count} ->
        body = Jason.encode!(%{status: "materialized", inferred: count})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        Logger.error("[Knowledge] reasoner failed: #{inspect(reason)}")
        json_error(conn, 500, "reason_failed", inspect(reason))
    end
  end

  # ── GET /context/:agent_id — get agent context ─────────────────────

  get "/context/:agent_id" do
    ensure_store_started()

    agent_id = conn.params["agent_id"]

    ctx = MiosaKnowledge.Context.for_agent(store(), agent_id: agent_id)
    prompt = MiosaKnowledge.Context.to_prompt(ctx)

    body = Jason.encode!(%{agent_id: agent_id, context: prompt})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /count — triple count ──────────────────────────────────────

  get "/count" do
    ensure_store_started()

    case MiosaKnowledge.count(store()) do
      {:ok, n} ->
        body = Jason.encode!(%{count: n})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, reason} ->
        Logger.error("[Knowledge] count failed: #{inspect(reason)}")
        json_error(conn, 500, "count_failed", inspect(reason))
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Knowledge endpoint not found")
  end

  # ── Private helpers ────────────────────────────────────────────────

  defp store do
    :osa_knowledge_default
  end

  defp ensure_store_started do
    # MiosaKnowledge stub uses an ETS table internally — no GenServer required.
    # The open/1 call is idempotent (ETS table creation is guarded inside the stub).
    MiosaKnowledge.open("osa_default")
    :ok
  end

  defp maybe_pattern(pattern, _key, nil), do: pattern
  defp maybe_pattern(pattern, _key, ""), do: pattern
  defp maybe_pattern(pattern, key, value), do: [{key, value} | pattern]
end
