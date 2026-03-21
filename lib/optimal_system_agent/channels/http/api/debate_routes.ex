defmodule OptimalSystemAgent.Channels.HTTP.API.DebateRoutes do
  @moduledoc """
  HTTP API routes for the multi-agent debate endpoint.

  Mounts at `/api/v1/debate` (configured in the parent router).

  Endpoints:

    POST /   — run a debate
      Body (JSON): { "message": string, "providers"?: [string], "timeout"?: integer,
                     "synthesizer_provider"?: string, "user_id"?: string, "model"?: string }
      200 → debate result map
      400 → invalid_request (missing or empty message)
      500 → all providers failed
  """

  use Plug.Router

  alias OptimalSystemAgent.Agent.Debate

  plug :match
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  plug :dispatch

  # POST / — run a debate
  post "/" do
    message = conn.body_params["message"]

    cond do
      is_nil(message) or message == "" ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{
          error: "invalid_request",
          details: "Required field 'message' is missing or empty"
        }))

      not is_binary(message) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{
          error: "invalid_request",
          details: "Field 'message' must be a string"
        }))

      true ->
        opts = build_opts(conn.body_params)

        case Debate.run(message, opts) do
          {:ok, result} ->
            body = %{
              synthesis: result.synthesis,
              debate: Enum.map(result.debate, fn d -> %{provider: d.provider, response: d.response} end),
              participants: result.participants
            }

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(body))

          {:error, :no_providers} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{
              error: "no_providers",
              details: "No providers specified and no default provider configured"
            }))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, Jason.encode!(%{
              error: "debate_failed",
              details: inspect(reason)
            }))
        end
    end
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "not_found"}))
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  defp build_opts(params) do
    []
    |> maybe_put(:providers, params["providers"])
    |> maybe_put(:timeout, params["timeout"])
    |> maybe_put(:synthesizer_provider, params["synthesizer_provider"])
    |> maybe_put(:user_id, params["user_id"])
    |> maybe_put(:model, params["model"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
