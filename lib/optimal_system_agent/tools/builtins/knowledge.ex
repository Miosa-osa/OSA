defmodule OptimalSystemAgent.Tools.Builtins.Knowledge do
  @behaviour MiosaTools.Behaviour

  @impl true
  def available?, do: true

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "knowledge"

  @impl true
  def description do
    "Query or modify the semantic knowledge graph. " <>
      "Assert facts, query patterns, or get agent context."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["query", "assert", "retract", "context", "count", "sparql", "reason"],
          "description" => "Action to perform"
        },
        "subject" => %{
          "type" => "string",
          "description" => "Subject of the triple (for query/assert/retract)"
        },
        "predicate" => %{
          "type" => "string",
          "description" => "Predicate/relationship (for query/assert/retract)"
        },
        "object" => %{
          "type" => "string",
          "description" => "Object/value (for query/assert/retract)"
        },
        "agent_id" => %{
          "type" => "string",
          "description" => "Agent ID for context action"
        },
        "sparql_query" => %{
          "type" => "string",
          "description" => "SPARQL query string (for sparql action)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(args) do
    ensure_store_started()

    case Map.get(args, "action") do
      "assert" -> do_assert(args)
      "retract" -> do_retract(args)
      "query" -> do_query(args)
      "context" -> do_context(args)
      "count" -> do_count()
      "sparql" -> do_sparql(args)
      "reason" -> do_reason()
      other -> {:error, "Unknown action: #{other}"}
    end
  rescue
    e -> {:error, "Knowledge service error: #{Exception.message(e)}"}
  end

  # --- Actions ---

  defp do_assert(%{"subject" => s, "predicate" => p, "object" => o})
       when is_binary(s) and is_binary(p) and is_binary(o) do
    case MiosaKnowledge.assert(store(), {s, p, o}) do
      :ok -> {:ok, "Asserted: (#{s}, #{p}, #{o})"}
      {:error, reason} -> {:error, "Assert failed: #{inspect(reason)}"}
    end
  end

  defp do_assert(_), do: {:error, "assert requires subject, predicate, and object"}

  defp do_retract(%{"subject" => s, "predicate" => p, "object" => o})
       when is_binary(s) and is_binary(p) and is_binary(o) do
    case MiosaKnowledge.retract(store(), {s, p, o}) do
      :ok -> {:ok, "Retracted: (#{s}, #{p}, #{o})"}
      {:error, reason} -> {:error, "Retract failed: #{inspect(reason)}"}
    end
  end

  defp do_retract(_), do: {:error, "retract requires subject, predicate, and object"}

  defp do_query(args) do
    pattern =
      []
      |> maybe_add(:subject, Map.get(args, "subject"))
      |> maybe_add(:predicate, Map.get(args, "predicate"))
      |> maybe_add(:object, Map.get(args, "object"))

    case MiosaKnowledge.query(store(), pattern) do
      {:ok, []} ->
        {:ok, "No matching triples found."}

      {:ok, results} ->
        formatted =
          results
          |> Enum.map(fn {s, p, o} -> "  (#{s}) --[#{p}]--> (#{o})" end)
          |> Enum.join("\n")

        {:ok, "Found #{length(results)} triples:\n#{formatted}"}

      {:error, reason} ->
        {:error, "Query failed: #{inspect(reason)}"}
    end
  end

  defp do_context(args) do
    agent_id = Map.get(args, "agent_id", "default")
    ctx = MiosaKnowledge.Context.for_agent(store(), agent_id: agent_id)
    {:ok, MiosaKnowledge.Context.to_prompt(ctx)}
  end

  defp do_count do
    case MiosaKnowledge.count(store()) do
      {:ok, n} -> {:ok, "Knowledge graph contains #{n} triples."}
      {:error, reason} -> {:error, "Count failed: #{inspect(reason)}"}
    end
  end

  defp do_sparql(%{"sparql_query" => query}) when is_binary(query) do
    case MiosaKnowledge.sparql(store(), query) do
      {:ok, results} when is_list(results) ->
        formatted =
          results
          |> Enum.map(fn bindings ->
            bindings
            |> Enum.map(fn {k, v} -> "  #{k} = #{v}" end)
            |> Enum.join(", ")
          end)
          |> Enum.join("\n")

        {:ok, "SPARQL results (#{length(results)} rows):\n#{formatted}"}

      {:ok, :inserted, count} ->
        {:ok, "Inserted #{count} triples."}

      {:ok, :deleted, count} ->
        {:ok, "Deleted #{count} triples."}

      {:error, reason} ->
        {:error, "SPARQL error: #{inspect(reason)}"}
    end
  end

  defp do_sparql(_), do: {:error, "sparql action requires sparql_query parameter"}

  defp do_reason do
    store_ref = store()

    try do
      case :sys.get_state(store_ref) do
        %{backend: backend, backend_state: backend_state} ->
          case MiosaKnowledge.Reasoner.materialize(backend, backend_state) do
            {:ok, _new_state, rounds} ->
              {:ok, "Reasoning complete. #{rounds} rounds of inference applied."}
          end

        _ ->
          {:error, "Could not access store state for reasoning"}
      end
    catch
      :exit, _ -> {:error, "Knowledge store not running"}
    end
  end

  # --- Helpers ---

  defp maybe_add(pattern, _key, nil), do: pattern
  defp maybe_add(pattern, key, value), do: [{key, value} | pattern]

  defp store do
    {:via, Registry, {MiosaKnowledge.Registry, "osa_default"}}
  end

  defp ensure_store_started do
    case GenServer.whereis(store()) do
      nil ->
        MiosaKnowledge.open("osa_default")

      _pid ->
        :ok
    end
  end
end
