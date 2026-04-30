defmodule OptimalSystemAgent.Channels.HTTP.API.SkillBootstrapRoutes do
  @moduledoc """
  POST /agent/skill — create a skill and immediately use it.

  OSA authors a new SKILL.md, registers it, opens a fresh session,
  and dispatches a trigger message so the agent executes the skill
  instructions in the same request cycle.

  Request body (JSON):
    {
      "name": "my-skill",           // kebab-case, required
      "description": "...",         // one-line description, required
      "instructions": "...",        // full instruction body, required
      "triggers": ["my-skill"],     // optional; defaults to [name]
      "tools": ["shell_execute"]    // optional
    }

  Response 202:
    {
      "status": "created_and_running",
      "skill_name": "my-skill",
      "session_id": "uuid",
      "trigger_message": "my-skill: ..."
    }

  GET /agent/skill — list all self-created skills.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Agent.SkillBootstrap

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  # ── POST /agent/skill ─────────────────────────────────────────────

  post "/" do
    body = conn.body_params

    name = body["name"]
    description = body["description"]
    instructions = body["instructions"]

    cond do
      not (is_binary(name) && name != "") ->
        json_error(conn, 400, "missing_name", "Skill 'name' (kebab-case string) is required")

      not (is_binary(description) && description != "") ->
        json_error(conn, 400, "missing_description", "'description' is required")

      not (is_binary(instructions) && instructions != "") ->
        json_error(conn, 400, "missing_instructions", "'instructions' body is required")

      not Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name) ->
        json_error(conn, 400, "invalid_name", "Skill name must be kebab-case. Got: #{name}")

      true ->
        skill_params =
          Map.take(body, ["name", "description", "instructions", "triggers", "tools"])

        case SkillBootstrap.create_and_run(skill_params) do
          {:ok, %{skill_name: sname, session_id: sid, trigger_message: msg}} ->
            resp =
              Jason.encode!(%{
                status: "created_and_running",
                skill_name: sname,
                session_id: sid,
                trigger_message: msg
              })

            conn |> put_resp_content_type("application/json") |> send_resp(202, resp)

          {:error, reason} ->
            json_error(conn, 500, "skill_bootstrap_failed", inspect(reason))
        end
    end
  end

  # ── GET /agent/skill ──────────────────────────────────────────────

  get "/" do
    skills = SkillBootstrap.list_self_skills()
    body = Jason.encode!(%{skills: skills, count: length(skills)})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  match _ do
    json_error(conn, 404, "not_found", "Endpoint not found")
  end
end
