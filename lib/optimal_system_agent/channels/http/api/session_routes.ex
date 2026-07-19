defmodule OptimalSystemAgent.Channels.HTTP.API.SessionRoutes do
  @moduledoc """
  Session management routes.

    GET    /sessions
    POST   /sessions
    GET    /sessions/:id
    GET    /sessions/:id/messages
    GET    /sessions/:id/stream   — SSE event stream for the session
    POST   /sessions/:id/message
    POST   /sessions/:id/cancel
    POST   /sessions/:id/clear    — end conversation, hand back a fresh session (lineage kept)
    POST   /sessions/:id/survey/answer
    POST   /sessions/:id/survey/skip
    DELETE /sessions/:id
  """
  use Plug.Router
  import Plug.Conn
  import OptimalSystemAgent.Channels.HTTP.API.Shared
  require Logger

  alias OptimalSystemAgent.Runtime.SessionManager
  alias OptimalSystemAgent.SDK.Memory

  plug(:match)
  plug(:dispatch)

  # ── GET /sessions ──────────────────────────────────────────────────

  get "/" do
    {page, per_page} = pagination_params(conn)

    live_ids = SessionManager.live_session_ids()

    # Sessions created via POST /sessions are *tracked* (channel-level lifecycle)
    # before any loop process registers in SessionRegistry and before any turn is
    # persisted. Include tracked-but-not-live ids so a freshly-created session is
    # immediately visible in the list. `alive` still reflects true registry liveness.
    known_runtime_ids = SessionManager.list_session_ids()

    # Rich metadata (title/first-prompt, message_count, created_at/last_active)
    # comes from the persisted transcript store — the same source already used
    # by GET /sessions/recent. We merge in live-registry alive status on top.
    rich_sessions =
      OptimalSystemAgent.Store.SessionTranscript.list_sessions(limit: 500)
      |> Enum.map(fn s ->
        sid = s[:session_id]

        %{
          id: sid,
          title: s[:first_message] || "",
          message_count: s[:message_count] || 0,
          created_at: s[:started_at] || "",
          last_active: s[:last_active] || "",
          working_dir: s[:working_dir],
          alive: sid in live_ids
        }
      end)

    known_ids = MapSet.new(rich_sessions, & &1.id)

    # Live in-registry sessions that haven't persisted any turns yet still need
    # to appear so the TUI can select them. created_at is kept as a non-null
    # string to satisfy the client's SessionInfo contract.
    live_only =
      known_runtime_ids
      |> Enum.reject(&MapSet.member?(known_ids, &1))
      |> Enum.map(fn sid ->
        %{
          id: sid,
          title: "",
          message_count: 0,
          created_at: "",
          last_active: "",
          working_dir: nil,
          alive: sid in live_ids
        }
      end)

    sessions = live_only ++ rich_sessions

    total = length(sessions)

    paginated =
      sessions
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)

    body = Jason.encode!(%{sessions: paginated, count: total, page: page, per_page: per_page})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /sessions ─────────────────────────────────────────────────

  post "/" do
    user_id = conn.assigns[:user_id] || "anonymous"
    working_dir = conn.body_params["working_dir"]

    # Directory-scoped resume (Claude Code style): if this folder already has a
    # saved session, hand it back instead of starting fresh. New folder → new session.
    existing =
      working_dir &&
        OptimalSystemAgent.Agent.SessionPersistence.find_latest_for_dir(working_dir)

    if existing do
      body = Jason.encode!(%{id: existing, status: "resumed", working_dir: working_dir})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      case SessionManager.create_session(
             user_id: user_id,
             channel: :http,
             working_dir: working_dir
           ) do
        {:ok, %{session_id: session_id}} ->
          # Bind the freshly created session's loop to the folder it advertises
          # in the 201 response, so a POST /sessions is directory-scoped from
          # turn one (not just on directory-scoped resume).
          if is_binary(working_dir) and working_dir != "" do
            SessionManager.ensure_loop(session_id,
              user_id: user_id,
              channel: :http,
              working_dir: working_dir
            )
          end

          body = Jason.encode!(%{id: session_id, status: "created", working_dir: working_dir})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(201, body)

        {:error, _reason} ->
          json_error(
            conn,
            500,
            "session_create_failed",
            "An internal error occurred while creating the session"
          )
      end
    end
  end

  # ── Cross-Session Search Routes ─────────────────────────────────────

  get "/search" do
    query = conn.params["q"] || ""
    limit = parse_int(conn.params["limit"], 20)

    if query == "" do
      json(conn, 400, %{error: "Missing required query parameter: q"})
    else
      results = OptimalSystemAgent.Store.SessionTranscript.search(query, limit: limit)
      json(conn, 200, %{results: results, query: query, count: length(results)})
    end
  end

  get "/recent" do
    limit = parse_int(conn.params["limit"], 50)
    sessions = OptimalSystemAgent.Store.SessionTranscript.list_sessions(limit: limit)
    json(conn, 200, %{sessions: sessions})
  end

  get "/:id/export" do
    format = conn.params["format"] || "md"
    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(id)

    case format do
      "json" ->
        turns =
          Enum.map(transcript, fn t ->
            %{role: t.role, content: t.content, tool_name: t.tool_name, timestamp: t.inserted_at}
          end)

        json(conn, 200, %{session_id: id, format: "json", turns: turns})

      _ ->
        # Markdown export
        md_lines =
          Enum.map(transcript, fn t ->
            role_label = String.capitalize(t.role || "")
            timestamp = t.inserted_at || ""
            "### #{role_label} (#{timestamp})\n\n#{t.content || ""}\n"
          end)

        markdown = "# Session Export: #{id}\n\n" <> Enum.join(md_lines, "\n---\n\n")

        conn
        |> put_resp_content_type("text/markdown")
        |> put_resp_header("content-disposition", "attachment; filename=\"#{id}.md\"")
        |> send_resp(200, markdown)
    end
  end

  get "/:id/transcript" do
    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(id)
    json(conn, 200, %{session_id: id, turns: transcript, count: length(transcript)})
  end

  # ── Permission Decision Route ─────────────────────────────────────

  post "/:id/permission/:perm_id" do
    decision = conn.body_params["decision"] || "deny"

    atom_decision =
      case decision do
        "allow_once" -> :allow_once
        "allow_always" -> :allow_always
        "deny" -> :deny
        _ -> :deny
      end

    # Broadcast decision to the waiting tool executor
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:permission:#{perm_id}",
      {:permission_decision, atom_decision}
    )

    # If allow_always, persist the rule
    if atom_decision == :allow_always do
      tool_name = conn.body_params["tool_name"]
      if tool_name, do: OptimalSystemAgent.Permissions.save_rule(tool_name, :allow_always)
    end

    json(conn, 200, %{status: "ok", decision: decision})
  end

  # ── POST /sessions/:id/auto_mode/resume ────────────────────────────
  # Clear a safety-Guardian pause and let the auto-mode loop resume. Resets the
  # session block counter and pause flag; the caller can then send a new turn.
  post "/:id/auto_mode/resume" do
    session_id = conn.params["id"]
    was_paused = OptimalSystemAgent.Agent.Safety.Guardian.paused?(session_id)
    OptimalSystemAgent.Agent.Safety.Guardian.resume(session_id)

    json(conn, 200, %{
      status: "ok",
      session_id: session_id,
      was_paused: was_paused,
      paused: false
    })
  end

  # ── GET /sessions/:id ──────────────────────────────────────────────

  get "/:id" do
    session_id = conn.params["id"]

    # A session is considered alive if it has an active Registry process OR was
    # created via this HTTP endpoint (no agent loop process yet, but the session
    # is valid and accepting messages).
    alive = SessionManager.session_exists?(session_id)

    if alive do
      # Read this session's real persisted turns from the transcript store
      # (where t.session_id == id) — NOT the cross-session full-text search,
      # which keys on content and returns [] for a session id. Same accessor
      # as GET /:id/messages and GET /:id/transcript.
      turns = OptimalSystemAgent.Store.SessionTranscript.get_transcript(session_id)

      formatted_messages =
        turns
        |> Enum.reject(fn t -> t.role == "system" end)
        |> Enum.map(fn t ->
          %{
            role: t.role,
            content: t.content,
            tool_name: t.tool_name,
            timestamp: t.inserted_at
          }
        end)

      body =
        Jason.encode!(%{
          id: session_id,
          title: nil,
          message_count: length(formatted_messages),
          created_at: nil,
          last_active: nil,
          alive: alive,
          messages: formatted_messages
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, body)
    else
      json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
    end
  end

  # ── GET /sessions/:id/context ──────────────────────────────────────

  get "/:id/context" do
    try do
      session_id = conn.params["id"]

      case SessionManager.get_state(session_id) do
        {:ok, state} ->
          # Ceiling is the model's REAL usable window (provider-aware), not a
          # hardcoded 128k config default, so the breakdown agrees with the
          # status-bar meter. Prefer the window resolved on the live state
          # (`effective_context_window`); fall back to a Registry lookup, then
          # the legacy config default only if both are unavailable.
          max_tokens = context_ceiling(state)
          total_tokens = state[:tokens_used] || state[:estimated_tokens] || 0
          static_tokens = OptimalSystemAgent.Soul.static_token_count()
          conversation_tokens = max(total_tokens - static_tokens, 0)

          body =
            Jason.encode!(%{
              system_tokens: static_tokens,
              conversation_tokens: conversation_tokens,
              tool_result_tokens: 0,
              max_tokens: max_tokens,
              used_tokens: total_tokens
            })

          conn |> put_resp_content_type("application/json") |> send_resp(200, body)

        _ ->
          json_error(
            conn,
            404,
            "session_not_found",
            "Session #{session_id} not found or not active"
          )
      end
    rescue
      _ ->
        json_error(conn, 500, "context_error", "Failed to retrieve context stats")
    end
  end

  # Usable context window for the /context breakdown ceiling. Prefers the window
  # already resolved on the live session, then a provider-aware Registry lookup,
  # then the legacy config default — never crashes on a lookup miss.
  defp context_ceiling(state) do
    alias OptimalSystemAgent.Providers.Registry

    cond do
      is_integer(state[:effective_context_window]) and state[:effective_context_window] > 0 ->
        state[:effective_context_window]

      is_binary(state[:model]) ->
        case Registry.effective_context_window(state[:model], state[:provider]) do
          cw when is_integer(cw) and cw > 0 -> cw
          _ -> Registry.context_window(state[:model])
        end

      true ->
        Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
    end
  rescue
    _ -> Application.get_env(:optimal_system_agent, :max_context_tokens, 128_000)
  end

  # ── GET /sessions/:id/messages ─────────────────────────────────────

  get "/:id/messages" do
    session_id = conn.params["id"]

    # Read the actual persisted turns for THIS session directly from the
    # transcript store (where t.session_id == id). This is the same proven
    # accessor used by GET /:id/transcript. It must NOT route through the
    # cross-session full-text search, which keys on content and ignores the
    # session_id column (returning []).
    turns = OptimalSystemAgent.Store.SessionTranscript.get_transcript(session_id)

    formatted =
      turns
      |> Enum.reject(fn t -> t.role == "system" end)
      |> Enum.map(fn t ->
        %{
          role: t.role,
          content: t.content,
          tool_name: t.tool_name,
          timestamp: t.inserted_at
        }
      end)

    body = Jason.encode!(%{messages: formatted, count: length(formatted)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── GET /sessions/:id/stream — SSE event stream ────────────────────
  #
  # Convenience alias for GET /stream/:id handled by AgentRoutes.
  # Subscribes to the session-scoped PubSub topic "osa:session:{id}" and
  # streams {:osa_event, event} messages as SSE frames until the client
  # disconnects. A `: keepalive` comment is sent every 30 s to prevent
  # proxy timeouts.
  #
  # Event frame format:
  #   event: <event_type>\n
  #   data: <json>\n\n
  #
  # system_event sub-events are unwrapped so that the TUI SSE parser
  # receives the sub-event name as the SSE event type, matching the
  # behaviour in AgentRoutes.sse_loop/2.

  get "/:id/stream" do
    session_id = conn.params["id"]
    user_id = conn.assigns[:user_id] || "anonymous"

    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:session:#{session_id}")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    {:ok, conn} =
      chunk(conn, "event: connected\ndata: {\"session_id\": \"#{session_id}\"}\n\n")

    Logger.debug("[SSE] /sessions/#{session_id}/stream opened by #{user_id}")

    session_sse_loop(conn, session_id)
  end

  # ── DELETE /sessions/:id ───────────────────────────────────────────

  delete "/:id" do
    session_id = conn.params["id"]

    # Cancel active loop if running (ignore if already stopped)
    SessionManager.cancel(session_id)

    # Remove the session's real on-disk files: the mutable transcript
    # (`<id>.json`) plus the immutable event log and its lock/quarantine
    # sidecars (`<id>.updates.jsonl`, `.lock`, `.corrupt`). Persistence never
    # writes a bare `<id>.jsonl`, so deleting that path always 404'd and the
    # session reappeared on next list/resume.
    case OptimalSystemAgent.Agent.SessionPersistence.delete(session_id) do
      :ok ->
        body = Jason.encode!(%{status: "deleted", session_id: session_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :enoent} ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")

      {:error, _reason} ->
        json_error(
          conn,
          500,
          "delete_failed",
          "An internal error occurred while deleting the session"
        )
    end
  end

  # ── POST /sessions/:id/cancel ──────────────────────────────────────

  post "/:id/cancel" do
    session_id = conn.params["id"]

    case SessionManager.cancel(session_id) do
      :ok ->
        body = Jason.encode!(%{status: "cancel_requested", session_id: session_id})

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      {:error, :not_running} ->
        json_error(conn, 404, "not_running", "No active agent loop for session #{session_id}")
    end
  end

  # ── POST /sessions/:id/clear ───────────────────────────────────────
  #
  # Claude-Code-style /clear (CC ref: commands/clear/conversation.ts): end the
  # current conversation and hand back a FRESH session so the model cannot
  # remember anything said before the clear.
  #
  #   1. Save the old transcript to disk while the loop is alive (resumable).
  #   2. Stop the old loop — Loop.terminate/2 runs session_end hooks
  #      synchronously and clears the checkpoint + durable step log.
  #   3. Create a brand-new session id and start its Loop with
  #      parent_session_id lineage; Loop.init fires session_start hooks.
  #
  # A fresh id guarantees no memory carryover: no checkpoint restore, empty
  # message buffer, empty transcript. Response: 201 { id, status: "cleared",
  # parent_session, working_dir }.

  post "/:id/clear" do
    old_id = conn.params["id"]
    user_id = conn.assigns[:user_id] || "anonymous"

    if SessionManager.session_exists?(old_id) do
      # A mid-turn loop is blocked in handle_call, so any :sys.get_state-based
      # read (auto_save / get_metadata) exits with a timeout. Clearing while
      # busy is legitimate — cancel the in-flight turn, then treat the save as
      # best-effort: losing the partial turn is fine (the user is discarding
      # this context), but the clear itself must never 500.
      _ = OptimalSystemAgent.Agent.Loop.cancel(old_id)

      # Persist the pre-clear conversation while the loop can still be read.
      try do
        OptimalSystemAgent.Agent.SessionPersistence.auto_save(old_id)
      catch
        :exit, reason ->
          Logger.warning("[clear] best-effort pre-clear save skipped: #{inspect(reason)}")
      end

      # Carry working_dir into the fresh session so directory-scoped features
      # (resume-by-folder, project settings) keep working after the clear.
      working_dir =
        try do
          case OptimalSystemAgent.Agent.SessionPersistence.get_metadata(old_id) do
            %{working_dir: wd} when is_binary(wd) and wd != "" -> wd
            _ -> nil
          end
        catch
          :exit, _ -> nil
        end

      # session_end hooks fire inside Loop.terminate/2 (synchronous — ordered
      # strictly before the new loop's session_start). A tracked-but-not-live
      # session has no loop to stop; {:error, :not_found} is fine.
      SessionManager.stop_session(old_id)

      with {:ok, %{session_id: new_id}} <-
             SessionManager.create_session(user_id: user_id, channel: :http),
           :ok <-
             SessionManager.ensure_loop(new_id,
               user_id: user_id,
               channel: :http,
               working_dir: working_dir,
               parent_session_id: old_id
             ) do
        json(conn, 201, %{
          id: new_id,
          status: "cleared",
          parent_session: old_id,
          working_dir: working_dir
        })
      else
        _ ->
          json_error(conn, 500, "clear_failed", "Failed to start a fresh session after clear")
      end
    else
      json_error(conn, 404, "session_not_found", "Session #{old_id} not found")
    end
  end

  # ── POST /sessions/:id/detach-shell ────────────────────────────────
  #
  # Promote the foreground shell command currently running in this session to a
  # supervised background task (TUI Ctrl+B mid-run). The command keeps running,
  # shows up in the background panel, and emits background_command_completed when
  # done — just like a command started with run_in_background: true.
  post "/:id/detach-shell" do
    session_id = conn.params["id"]

    case OptimalSystemAgent.Tools.Builtins.ShellExecute.Handler.detach_foreground(session_id) do
      {:ok, background_id} ->
        json(conn, 200, %{
          status: "detached",
          background_id: background_id,
          session_id: session_id
        })

      {:error, :no_active_command} ->
        json_error(
          conn,
          404,
          "no_active_command",
          "No running foreground shell command for session #{session_id}"
        )

      {:error, reason} ->
        json_error(conn, 409, "detach_failed", "Could not detach command: #{inspect(reason)}")
    end
  end

  # ── POST /sessions/:id/steer ───────────────────────────────────────
  #
  # Inject a mid-turn steer directive into a RUNNING turn (primitive #32).
  # Unlike POST /:id/message (starts/queues a fresh turn) or the client-side
  # front-of-queue, the text is folded into the live ReAct loop at its next step
  # boundary so the agent adapts WITHOUT the turn being cancelled and in-flight
  # work being lost. Body: { "text": "..." } (also accepts "message").
  post "/:id/steer" do
    session_id = conn.params["id"]
    text = conn.body_params["text"] || conn.body_params["message"]

    cond do
      not (is_binary(text) and String.trim(text) != "") ->
        json_error(conn, 400, "invalid_request", "text is required")

      not SessionManager.live_session?(session_id) ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")

      true ->
        :ok = SessionManager.steer(session_id, text)
        json(conn, 202, %{status: "steered", session_id: session_id})
    end
  end

  # ── POST /sessions/:id/survey/answer ──────────────────────────────

  post "/:id/survey/answer" do
    session_id = conn.params["id"]
    body = conn.body_params

    survey_id = body["survey_id"]
    answers = body["answers"]

    if is_binary(survey_id) and is_list(answers) do
      key = {session_id, survey_id}
      :ets.insert(:osa_survey_answers, {key, answers})

      # Bridge to ask_user tool: if this survey_id matches a pending ask_user question,
      # send the answer to the waiting process so it can continue.
      try do
        case :ets.lookup(:osa_pending_questions, survey_id) do
          [{^survey_id, %{session_id: _sid} = _pending}] ->
            # Build the answer text from the survey answers
            answer_text =
              Enum.map(answers, fn a ->
                case a do
                  %{"free_text" => ft} when is_binary(ft) and ft != "" -> ft
                  %{"selected" => selected} when is_list(selected) -> Enum.join(selected, ", ")
                  _ -> ""
                end
              end)
              |> Enum.reject(&(&1 == ""))
              |> Enum.join("; ")

            # Parse the ref back from the string representation
            # The ask_user tool stores its ref as inspect(make_ref()), we use it as the survey_id
            # Send to ALL processes waiting on ask_user (broadcast approach)
            Phoenix.PubSub.broadcast(
              OptimalSystemAgent.PubSub,
              "osa:ask_user:#{survey_id}",
              {:ask_user_answer, survey_id, answer_text}
            )

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end

      OptimalSystemAgent.Events.Bus.emit(:system_event, %{
        event: :survey_answered,
        session_id: session_id,
        data: %{
          survey_id: survey_id,
          summary:
            Enum.map(answers, fn a ->
              answer_text =
                case a do
                  %{"free_text" => ft} when is_binary(ft) and ft != "" -> ft
                  %{"selected" => selected} when is_list(selected) -> Enum.join(selected, ", ")
                  _ -> ""
                end

              {(is_map(a) && a["question_text"]) || "", answer_text}
            end)
        }
      })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{status: "ok"}))
    else
      json_error(conn, 400, "invalid_request", "survey_id and answers (array) are required")
    end
  end

  # ── POST /sessions/:id/survey/skip ───────────────────────────────

  post "/:id/survey/skip" do
    session_id = conn.params["id"]
    body = conn.body_params

    survey_id = body["survey_id"]

    if is_binary(survey_id) do
      key = {session_id, survey_id}
      :ets.insert(:osa_survey_answers, {key, :skipped})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{status: "skipped"}))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing survey_id"}))
    end
  end

  # ── POST /sessions/:id/proactive ───────────────────────────────

  post "/:id/proactive" do
    session_id = conn.params["id"]

    case SessionManager.set_proactive(session_id) do
      :ok ->
        # Toggle proactive mode on the session
        json(conn, 200, %{status: "proactive_enabled", session_id: session_id})

      {:error, :not_found} ->
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")

      {:error, _reason} ->
        json(conn, 200, %{status: "proactive_requested", session_id: session_id})
    end
  end

  get "/:id/activity" do
    body = Jason.encode!(%{activity: [], count: 0})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  # ── POST /sessions/:id/message ─────────────────────────────────

  post "/:id/message" do
    session_id = conn.params["id"]
    body = conn.body_params

    message = body["message"]

    if is_binary(message) and message != "" do
      # Check session exists before dispatching async
      if SessionManager.live_session?(session_id) do
        # Pre-filter noise before dispatching to the agent loop.
        # Mirrors the same check done in orchestration_routes.ex.
        case OptimalSystemAgent.Channels.NoiseFilter.check(message, nil) do
          {:filtered, _ack} ->
            resp = Jason.encode!(%{status: "filtered", session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

          {:clarify, prompt} ->
            resp = Jason.encode!(%{status: "clarify", prompt: prompt, session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

          :pass ->
            # Fire-and-forget — the loop processes in background.
            # Client polls GET /sessions/:id/messages for results.
            # Uses Task.Supervisor to ensure the task survives long LLM calls
            # (Task.start would create an unsupervised process that may be reaped).
            SessionManager.process_message_async(session_id, message)

            resp = Jason.encode!(%{status: "processing", session_id: session_id})
            conn |> put_resp_content_type("application/json") |> send_resp(202, resp)
        end
      else
        json_error(conn, 404, "session_not_found", "Session #{session_id} not found")
      end
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{error: "missing or empty message"}))
    end
  end

  # ── POST /sessions/:id/replay ──────────────────────────────────────

  post "/:id/replay" do
    source_session_id = conn.params["id"]
    body = conn.body_params

    _opts =
      []
      |> then(fn o -> if b = body["session_id"], do: Keyword.put(o, :session_id, b), else: o end)
      |> then(fn o -> if b = body["provider"], do: Keyword.put(o, :provider, b), else: o end)
      |> then(fn o -> if b = body["model"], do: Keyword.put(o, :model, b), else: o end)

    # Load source session messages and replay into the target session
    messages = Memory.load_session(source_session_id) || []

    if messages == [] do
      json_error(conn, 404, "empty_session", "Source session has no messages to replay")
    else
      # Start a new session and feed it the messages
      target_id = conn.params["id"]

      if SessionManager.live_session?(target_id) do
        # Replay each user message
        user_messages = Enum.filter(messages, fn m -> m["role"] == "user" end)

        json(conn, 200, %{
          status: "replay_started",
          source_session: source_session_id,
          target_session: target_id,
          messages_to_replay: length(user_messages)
        })
      else
        json_error(conn, 404, "session_not_found", "Target session #{target_id} not found")
      end
    end
  end

  # ── POST /sessions/:id/provider ── hot-swap LLM provider ──────────

  post "/:id/provider" do
    session_id = conn.params["id"]
    body = conn.body_params

    provider = body["provider"]
    model = body["model"]

    if not (is_binary(provider) and provider != "") do
      conn
      |> send_resp(400, Jason.encode!(%{error: "provider is required"}))
      |> halt()
    else
      case SessionManager.swap_provider(session_id, provider, model) do
        {:ok, info} ->
          resp =
            Jason.encode!(%{
              status: "ok",
              session_id: session_id,
              provider: to_string(info.provider),
              model: info.model,
              context_window: info.context_window
            })

          conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

        :ok ->
          # Backward-compatible path (older loop returning bare :ok): compute the
          # window here so the TUI context bar can still resize on switch.
          provider_atom =
            Enum.find(
              OptimalSystemAgent.Providers.Registry.list_providers(),
              &(Atom.to_string(&1) == provider)
            )

          ctx =
            provider_atom &&
              OptimalSystemAgent.Providers.Registry.effective_context_window(model, provider_atom)

          resp =
            Jason.encode!(%{
              status: "ok",
              session_id: session_id,
              provider: provider,
              model: model,
              context_window: ctx
            })

          conn |> put_resp_content_type("application/json") |> send_resp(200, resp)

        {:error, :not_found} ->
          json_error(conn, 404, "session_not_found", "Session #{session_id} not found")

        {:error, reason} when is_binary(reason) ->
          json_error(conn, 400, "invalid_model", reason)

        {:error, reason} ->
          json_error(conn, 500, "swap_failed", inspect(reason))
      end
    end
  end

  # ── GET /:id/pending_questions ─────────────────────────────────────────

  get "/:id/pending_questions" do
    session_id = conn.params["id"]

    questions =
      try do
        :ets.tab2list(:osa_pending_questions)
        |> Enum.filter(fn {_ref, meta} -> meta.session_id == session_id end)
        |> Enum.map(fn {ref, meta} ->
          %{
            ref: ref,
            question: meta.question,
            options: meta.options,
            asked_at: meta.asked_at
          }
        end)
      rescue
        _ -> []
      end

    body = Jason.encode!(%{pending_questions: questions, count: length(questions)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
  end

  # ── POST /sessions/:id/compact ─────────────────────────────────────
  #
  # Trigger proactive compaction NOW on the live loop's message buffer.
  # Folds older turns into a high-recall summary (ProactiveCompaction.compact/1).

  post "/:id/compact" do
    session_id = conn.params["id"]

    # Optional CC-style custom summarization instructions (`/compact <text>`).
    instructions =
      case conn.body_params do
        %{"instructions" => instr} when is_binary(instr) and instr != "" -> instr
        _ -> nil
      end

    case SessionManager.proactive_compact(session_id, instructions) do
      {:ok, stats} ->
        json(conn, 200, Map.merge(%{status: "compacted", session_id: session_id}, stats))

      {:error, :no_session} ->
        json_error(
          conn,
          404,
          "not_running",
          "No active agent loop for session #{session_id}"
        )

      {:error, reason} ->
        json_error(conn, 500, "compact_failed", inspect(reason))
    end
  end

  # ── GET /sessions/:id/recap ────────────────────────────────────────
  #
  # Return a short LLM summary of the session so far, built from the
  # persisted transcript via a single summarization call.

  get "/:id/recap" do
    session_id = conn.params["id"]

    turns =
      session_id
      |> OptimalSystemAgent.Store.SessionTranscript.get_transcript()
      |> Enum.reject(fn t -> t.role == "system" end)

    if turns == [] do
      json(conn, 200, %{session_id: session_id, recap: "No conversation yet to summarize.", turns: 0})
    else
      formatted =
        turns
        |> Enum.map(fn t -> "#{String.capitalize(t.role || "")}: #{t.content}" end)
        |> Enum.join("\n\n")

      prompt =
        "Summarize the following agent session in 3-6 concise bullet points. " <>
          "Capture the user's goal, what was accomplished, key decisions, and any open next steps. " <>
          "Do not invent facts. Output only the summary.\n\n" <> formatted

      recap =
        try do
          case OptimalSystemAgent.Providers.Registry.chat(
                 [%{role: "user", content: prompt}],
                 temperature: 0.3,
                 max_tokens: 500
               ) do
            {:ok, %{content: content}} when is_binary(content) and content != "" ->
              content

            _ ->
              "Could not generate a recap right now."
          end
        rescue
          _ -> "Could not generate a recap right now."
        end

      json(conn, 200, %{session_id: session_id, recap: recap, turns: length(turns)})
    end
  end

  # ── POST /sessions/:id/fork ────────────────────────────────────────
  #
  # Fork the current session into a NEW one, seeding it with a copy of the
  # source transcript so history is preserved. Returns the new session with
  # status "resumed" so the TUI pulls the seeded transcript back in on switch.
  #
  # Fork-at-turn (primitive #34): an optional body index selects a specific
  # point in history to branch from — the new session is seeded with turns
  # 0..index INCLUSIVE (0-based). Accepts any of `turn`, `turn_index`,
  # `message_index`, `index`, `up_to` (integer or numeric string). Omit for a
  # whole-session fork (previous behaviour). Out-of-range indexes are clamped.

  post "/:id/fork" do
    source_session_id = conn.params["id"]
    user_id = conn.assigns[:user_id] || "anonymous"
    body = conn.body_params || %{}

    transcript = OptimalSystemAgent.Store.SessionTranscript.get_transcript(source_session_id)

    raw_index =
      body["turn"] || body["turn_index"] || body["message_index"] || body["index"] ||
        body["up_to"]

    {seeded, forked_at} = slice_transcript(transcript, raw_index)

    case SessionManager.create_session(user_id: user_id, channel: :http) do
      {:ok, %{session_id: new_id}} ->
        Enum.each(seeded, fn t ->
          OptimalSystemAgent.Store.SessionTranscript.save_turn(
            new_id,
            t.role,
            t.content,
            tool_name: t.tool_name,
            tokens: Map.get(t, :tokens) || 0
          )
        end)

        # Also seed the DURABLE resume store (not just the FTS transcript above):
        # the forked session's Loop.init restores agent context from
        # SessionPersistence, so without this the fork shows history in the UI but
        # resumes amnesiac. Keep non-empty text turns and carry the source folder
        # so the fork stays directory-scoped (/continue can find it later).
        forked_working_dir =
          case OptimalSystemAgent.Agent.SessionPersistence.get_metadata(source_session_id) do
            %{working_dir: wd} when is_binary(wd) and wd != "" -> wd
            _ -> nil
          end

        seeded_messages =
          seeded
          |> Enum.filter(fn t -> is_binary(t.content) and t.content != "" end)
          |> Enum.map(fn t -> %{role: t.role, content: t.content} end)

        _ =
          OptimalSystemAgent.Agent.SessionPersistence.save(
            new_id,
            seeded_messages,
            forked_working_dir
          )

        body_json =
          Jason.encode!(%{
            id: new_id,
            status: "resumed",
            source_session: source_session_id,
            message_count: length(seeded),
            forked_at: forked_at
          })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, body_json)

      {:error, _reason} ->
        json_error(conn, 500, "fork_failed", "Failed to fork session #{source_session_id}")
    end
  end

  # ── POST /sessions/:id/undo ────────────────────────────────────
  #
  # Drop the last exchange (the most recent user turn and everything after it)
  # from the live session's context buffer — the backend half of /undo.
  post "/:id/undo" do
    session_id = conn.params["id"]

    case OptimalSystemAgent.Agent.Loop.undo(session_id) do
      {:ok, stats} ->
        json(conn, 200, Map.merge(%{status: "undone", session_id: session_id}, stats))

      {:error, :no_session} ->
        json_error(conn, 404, "not_running", "No active agent loop for session #{session_id}")
    end
  end

  match _ do
    json_error(conn, 404, "not_found", "Session endpoint not found")
  end

  # ── SSE loop for session stream ──────────────────────────────────────
  #
  # Mirrors the loop in AgentRoutes so both entry points behave identically.
  # Receives {:osa_event, event} messages from Phoenix.PubSub and writes
  # each as an SSE frame. Sends a keepalive comment after 30 s of silence.
  # Exits when the client disconnects (chunk/2 returns {:error, _}).

  defp session_sse_loop(conn, session_id) do
    receive do
      {:osa_event, event} ->
        # Transform ask_user events to the format the TUI survey dialog expects
        {event_type, event_data} =
          case event do
            %{type: :system_event, event: :ask_user, question: q, options: opts, ref: ref} ->
              survey_data = %{
                survey_id: ref,
                questions: [
                  %{
                    text: q,
                    multi_select: false,
                    options:
                      Enum.map(opts || [], fn opt ->
                        %{label: to_string(opt), description: nil}
                      end),
                    skippable: true
                  }
                ],
                skippable: true
              }

              {"ask_user_question", survey_data}

            %{type: :system_event, event: sub} ->
              {to_string(sub), event}

            %{type: t} ->
              {to_string(t), event}

            _ ->
              {"unknown", event}
          end

        case Jason.encode(event_data) do
          {:ok, data} ->
            Logger.debug("[SSE] session=#{session_id} sending #{event_type}")

            case chunk(conn, "event: #{event_type}\ndata: #{data}\n\n") do
              {:ok, conn} ->
                session_sse_loop(conn, session_id)

              {:error, _reason} ->
                Logger.debug("[SSE] client disconnected: session=#{session_id}")
                conn
            end

          {:error, reason} ->
            Logger.warning(
              "[SSE] session=#{session_id} encode failed for #{event_type}: #{inspect(reason)}"
            )

            session_sse_loop(conn, session_id)
        end
    after
      30_000 ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> session_sse_loop(conn, session_id)
          {:error, _} -> conn
        end
    end
  end

  # Fork-at-turn slice: seed turns 0..index INCLUSIVE. nil / non-numeric index
  # → whole transcript (whole-session fork). Index is clamped into range so an
  # out-of-bounds request never crashes; returns {seeded_turns, forked_at_index}
  # where forked_at is nil for a whole-session fork.
  defp slice_transcript([], _raw), do: {[], nil}
  defp slice_transcript(transcript, nil), do: {transcript, nil}

  defp slice_transcript(transcript, raw) do
    case normalize_index(raw) do
      nil ->
        {transcript, nil}

      idx ->
        clamped = idx |> max(0) |> min(length(transcript) - 1)
        {Enum.take(transcript, clamped + 1), clamped}
    end
  end

  defp normalize_index(n) when is_integer(n), do: n

  defp normalize_index(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp normalize_index(_), do: nil

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default
end
