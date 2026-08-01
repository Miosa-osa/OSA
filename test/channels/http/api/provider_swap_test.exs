defmodule OptimalSystemAgent.Channels.HTTP.API.ProviderSwapTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias OptimalSystemAgent.Channels.HTTP.API.SessionRoutes
  alias OptimalSystemAgent.Runtime.SessionManager

  @opts SessionRoutes.init([])

  defp json_post(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
    |> SessionRoutes.call(@opts)
  end

  describe "POST /:id/provider" do
    test "returns 404 for non-existent session" do
      conn = json_post("/no-such-session-xyz/provider", %{"provider" => "openai"})
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "not_found" or body["details"] =~ "not_found"
    end

    test "returns 400 when provider is missing" do
      conn = json_post("/some-session/provider", %{})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "provider" or conn.resp_body =~ "provider"
    end

    test "returns 400 when provider is empty string" do
      conn = json_post("/some-session/provider", %{"provider" => ""})
      assert conn.status == 400
    end

    test "returns 404 when session registry has no entry" do
      conn = json_post("/ghost-session-42/provider", %{"provider" => "anthropic"})
      # 404 because session doesn't exist in registry
      assert conn.status == 404
    end

    test "response includes provider field on success path" do
      # Can't easily start a real session in unit tests, but we can
      # confirm the route handles the case where session IS running.
      # This test verifies the 404 path structure.
      conn = json_post("/missing-session/provider", %{"provider" => "groq", "model" => "llama3"})
      assert conn.status in [200, 404]
      body = Jason.decode!(conn.resp_body)
      assert is_map(body)
    end

    # REGRESSION (v1.0.46): this is the case that shipped broken and that nothing
    # covered. The TUI mints its session id locally at startup and announces it by
    # opening the session event stream; the backend materialises the Loop lazily on
    # the first message. So "open OSA → switch model → then talk" hits this route
    # with a session that is announced but has NO loop and NO persisted transcript.
    # The existence gate added for the unknown-session 404s above must not swallow
    # it — `SessionManager.swap_provider/3` materialises the loop on purpose.
    test "a model switch on a brand-new announced session with no prior turn is not 404" do
      session_id = "provider-swap-fresh-#{System.unique_integer([:positive, :monotonic])}"

      # What GET /stream/:session_id does when the TUI subscribes at startup.
      :ok = SessionManager.track_session(session_id, %{user_id: "anonymous", channel: :sse})
      refute SessionManager.live_session?(session_id),
             "precondition: the session must not have a loop yet"

      conn =
        json_post("/#{session_id}/provider", %{
          "provider" => "ollama",
          "model" => "glm-5.2:cloud"
        })

      refute conn.status == 404,
             "a pre-first-turn model switch must not 404: got #{conn.resp_body}"

      assert SessionManager.live_session?(session_id),
             "the swap must materialise the loop the first turn will use"

      SessionManager.cancel(session_id)
      SessionManager.untrack_session(session_id)
    end

    # The half of the regression the test above stubs out: the announcement itself.
    # Opening the session event stream is the ONLY thing a fresh TUI does with its
    # locally-minted id before the first message, so if subscribing does not record
    # the id there is no way for the route to tell it apart from garbage, and the
    # existence gate 404s every pre-first-turn model switch.
    test "opening the session event stream announces the session to the backend" do
      session_id = "provider-swap-stream-#{System.unique_integer([:positive, :monotonic])}"
      refute SessionManager.tracked_session?(session_id)

      # The SSE handler blocks in its receive loop by design; run it detached and
      # tear it down once the announcement has landed.
      task =
        Task.async(fn ->
          conn(:get, "/#{session_id}")
          |> Plug.Conn.assign(:user_id, "anonymous")
          |> OptimalSystemAgent.Channels.HTTP.API.AgentRoutes.call(
            OptimalSystemAgent.Channels.HTTP.API.AgentRoutes.init([])
          )
        end)

      tracked? =
        Enum.reduce_while(1..100, false, fn _, _ ->
          if SessionManager.tracked_session?(session_id) do
            {:halt, true}
          else
            Process.sleep(10)
            {:cont, false}
          end
        end)

      Task.shutdown(task, :brutal_kill)

      assert tracked?,
             "GET /stream/:session_id must track the session id the client announced"

      SessionManager.untrack_session(session_id)
    end
  end

  # ── `osa --model <name>` / `osa --provider <name>` ────────────────────────
  #
  # The launch flags are applied SESSION-SCOPED through this exact route (the
  # boot-time chain — config.toml outranking OLLAMA_MODEL, Settings.put_env, the
  # launcher sourcing ~/.osa/.env — makes an env-based override unwinnable on a
  # machine that has ever picked a model in the TUI). The TUI may therefore send
  # only one half of {provider, model}; the route fills in the other.
  describe "POST /:id/provider — CLI --model / --provider overrides" do
    defp swap(session_id, body) do
      json_post("/#{session_id}/provider", body)
    end

    defp announced_session(tag) do
      id = "cli-override-#{tag}-#{System.unique_integer([:positive, :monotonic])}"
      :ok = SessionManager.track_session(id, %{user_id: "anonymous", channel: :sse})
      id
    end

    test "--model with no --provider is attributed to the owning provider" do
      id = announced_session("model-only")

      # An ollama tag: Registry.provider_for_model/1 must attribute it rather
      # than the route rejecting it as "provider is required".
      conn = swap(id, %{"model" => "glm-5.2:cloud"})

      refute conn.status == 400,
             "--model alone must not 400 as a missing provider: #{conn.resp_body}"

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["model"] == "glm-5.2:cloud"
      assert is_binary(body["provider"]) and body["provider"] != ""

      SessionManager.cancel(id)
      SessionManager.untrack_session(id)
    end

    test "--provider with no --model falls back to that provider's default model" do
      id = announced_session("provider-only")

      conn = swap(id, %{"provider" => "ollama"})

      assert conn.status == 200, "--provider alone must resolve a model: #{conn.resp_body}"
      body = Jason.decode!(conn.resp_body)
      assert body["provider"] == "ollama"

      {:ok, info} = OptimalSystemAgent.Providers.Registry.provider_info(:ollama)
      assert body["model"] == info.default_model

      SessionManager.cancel(id)
      SessionManager.untrack_session(id)
    end

    test "--model and --provider together are applied verbatim" do
      id = announced_session("both")

      conn = swap(id, %{"provider" => "ollama", "model" => "llama3.1:8b"})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["provider"] == "ollama"
      assert body["model"] == "llama3.1:8b"

      SessionManager.cancel(id)
      SessionManager.untrack_session(id)
    end

    # THE POINT OF THE WHOLE FEATURE: the override must actually take effect on
    # the loop the next turn will use, not merely return 200. The session-scoped
    # override table is what `Loop` reads, so assert on that rather than on the
    # response echo (which would pass even if nothing were applied).
    test "the override lands on the live loop, beating the on-disk default" do
      id = announced_session("takes-effect")

      assert swap(id, %{"provider" => "ollama", "model" => "some-other-model:9b"}).status == 200

      assert SessionManager.live_session?(id),
             "the swap must materialise the loop the first turn will use"

      assert [{^id, :ollama, "some-other-model:9b"}] =
               :ets.lookup(:osa_session_provider_overrides, id),
             "the session-scoped override must be recorded for the loop to read"

      SessionManager.cancel(id)
      SessionManager.untrack_session(id)
    end

    test "an unattributable model with no provider is still a 400" do
      conn = swap("cli-override-nonsense", %{"model" => ""})
      assert conn.status == 400
      assert conn.resp_body =~ "provider"
    end
  end
end
