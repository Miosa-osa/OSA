defmodule OptimalSystemAgent.Channels.HTTP.API.SkillEvolutionRoutes do
  @moduledoc """
  GET  /agent/evolve         — stats: evolved_count, last_evolution
  GET  /agent/evolve/skills  — list evolved skill names
  POST /agent/evolve/trigger — manually trigger evolution for a session
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Agent.SkillEvolution

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/skills" do
    skills = SkillEvolution.list_evolved_skills()
    body = Jason.encode!(%{skills: skills, count: length(skills)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  get "/" do
    case SkillEvolution.stats() do
      {:ok, %{evolved_count: n, last_evolution: last}} ->
        body =
          Jason.encode!(%{
            evolved_count: n,
            last_evolution: if(last, do: DateTime.to_iso8601(last), else: nil),
            skills: SkillEvolution.list_evolved_skills()
          })

        conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end
  end

  post "/trigger" do
    session_id = conn.body_params["session_id"]
    reason = conn.body_params["reason"] || "manual"

    cond do
      not (is_binary(session_id) && session_id != "") ->
        json_error(conn, 400, "missing_session_id", "'session_id' is required")

      true ->
        failure_info = %{reason: reason}
        SkillEvolution.trigger_evolution(session_id, failure_info)

        body = Jason.encode!(%{status: "triggered", session_id: session_id})
        conn |> put_resp_content_type("application/json") |> send_resp(202, body)
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end
end
