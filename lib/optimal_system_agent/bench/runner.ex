defmodule OptimalSystemAgent.Bench.Runner do
  @moduledoc """
  Runs one task once and scores it.

  Two ways to drive the agent:

    * `:in_process` (default) - boots a session inside this BEAM (the code of
      the checkout being measured), exactly like `mix osa.run`, with the
      workspace as its working directory and permission mode `overdrive` so
      nothing parks on an approval nobody can answer.
    * `:http` - drives a running daemon (for example the installed release)
      over its API: `POST /api/v1/orchestrate` with the workspace as
      `working_dir`, then polls `GET /api/v1/sessions/:id/trace` until the turn
      is done and reads the reply from `GET /api/v1/sessions/:id/messages`.

  Either way the timings come from the daemon's own per-turn record
  (`Agent.TurnTrace`), the same data `/trace` shows.
  """

  require Logger

  alias OptimalSystemAgent.Agent.{Loop, TurnTrace}
  alias OptimalSystemAgent.Bench.{Check, Script, TaskSpec, Workspace}
  alias OptimalSystemAgent.Runtime.SessionManager

  @poll_ms 1_000

  @doc """
  Run `task` once. `opts`:

    * `:fixtures_dir`, `:work_root` - where fixtures live / workspaces go
    * `:provider`, `:model` - override the configured provider/model
    * `:control` - `:oracle` or `:nop` to replay a scripted control through the
      mock provider instead of asking a model
    * `:timeout_s` - per-task wall clock limit (task's own `:timeout_s` wins)
    * `:runner` - `:in_process` or `:http`; `:url`, `:token` (and
      `:req_options`, extra `Req` options, and `:shared_secret` to sign
      requests for a daemon running with `OSA_SHARED_SECRET`) for `:http`
    * `:keep_workspace` - leave the workspace on disk after scoring
    * `:attempt` - attempt number, recorded on the row
  """
  @spec run(TaskSpec.t(), keyword()) :: map()
  def run(%TaskSpec{} = task, opts) do
    fixture = Path.join(Keyword.fetch!(opts, :fixtures_dir), task.fixture)
    work_root = Keyword.fetch!(opts, :work_root)

    base = %{
      id: task.id,
      category: task.category,
      attempt: Keyword.get(opts, :attempt, 1),
      par_tool_calls: TaskSpec.par_tool_calls(task)
    }

    case Workspace.prepare(fixture, work_root, task.id, task.setup) do
      {:ok, dir} ->
        snapshot = Check.snapshot(dir, task.check)

        row =
          try do
            drive(task, dir, snapshot, opts)
          after
            unless Keyword.get(opts, :keep_workspace, false), do: File.rm_rf(dir)
          end

        Map.merge(base, Map.put(row, :workspace, if(Keyword.get(opts, :keep_workspace), do: dir)))

      {:error, reason} ->
        Map.merge(base, failed_row("setup_error", reason))
    end
  end

  defp drive(task, dir, snapshot, opts) do
    # A control is scripted; it must never reach a real (billed) model, whatever
    # the session would otherwise resolve as its default.
    opts =
      if Keyword.get(opts, :control) in [:oracle, :nop],
        do: Keyword.merge(opts, provider: :mock, model: "mock-model-1.0"),
        else: opts

    timeout_ms = (task.timeout_s || Keyword.get(opts, :timeout_s, 600)) * 1000
    session_id = "bench-#{task.id}-#{System.unique_integer([:positive])}"

    with_control(task, dir, opts, fn ->
      started = System.monotonic_time(:millisecond)

      {outcome, session_id} =
        case Keyword.get(opts, :runner, :in_process) do
          :http -> drive_http(task.prompt, dir, timeout_ms, opts)
          _ -> {drive_in_process(session_id, task.prompt, dir, timeout_ms, opts), session_id}
        end

      wall_ms = System.monotonic_time(:millisecond) - started

      {status, answer, trace, error} =
        case outcome do
          {:ok, answer, trace} -> {"done", answer, trace, nil}
          {:timeout, trace} -> {"timeout", "", trace, "no reply within #{div(timeout_ms, 1000)}s"}
          {:error, reason, trace} -> {"error", "", trace, reason}
        end

      {pass, checks} = Check.run(task.check, dir, answer, snapshot)

      Map.merge(metrics(trace, wall_ms), %{
        status: status,
        pass: pass and status == "done",
        checks: checks,
        error: error,
        answer: String.slice(answer || "", 0, 2_000),
        session_id: session_id,
        trace: trace
      })
    end)
  end

  # A control swaps the model for a scripted responder for the duration of the
  # task. The mock provider reads it from application env on every call.
  defp with_control(task, dir, opts, fun) do
    case Keyword.get(opts, :control) do
      mode when mode in [:oracle, :nop] ->
        Application.put_env(
          :optimal_system_agent,
          :mock_provider_script,
          Script.responder(mode, task.reference, dir)
        )

        try do
          fun.()
        after
          Application.delete_env(:optimal_system_agent, :mock_provider_script)
        end

      _ ->
        fun.()
    end
  end

  # ── in-process ───────────────────────────────────────────────────────

  defp drive_in_process(session_id, prompt, dir, timeout_ms, opts) do
    loop_opts =
      [
        channel: :headless,
        user_id: "bench",
        working_dir: dir,
        permission_mode: :overdrive,
        provider: provider_atom(Keyword.get(opts, :provider)),
        model: Keyword.get(opts, :model)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case SessionManager.ensure_loop(session_id, loop_opts) do
      :ok ->
        # Not linked: a turn that crashes must be scored as an error, not take
        # the whole bench run down with it.
        task =
          Task.Supervisor.async_nolink(OptimalSystemAgent.TaskSupervisor, fn ->
            Loop.process_message(session_id, prompt, working_dir: dir)
          end)

        result =
          case Task.yield(task, timeout_ms) do
            {:ok, {:ok, response}} ->
              {:ok, to_string(response), trace(session_id)}

            {:ok, {:error, reason}} ->
              {:error, inspect(reason), trace(session_id)}

            {:ok, other} ->
              {:ok, to_string(inspect(other)), trace(session_id)}

            {:exit, reason} ->
              {:error, "turn crashed: #{inspect(reason)}", trace(session_id)}

            nil ->
              Loop.cancel(session_id)
              Task.shutdown(task, 10_000)
              {:timeout, trace(session_id)}
          end

        stop_session(session_id, opts)
        result

      {:error, reason} ->
        {:error, "could not start a session: #{inspect(reason)}", nil}
    end
  end

  defp trace(session_id) do
    case TurnTrace.latest(session_id) do
      nil -> nil
      summary -> summary |> Jason.encode!() |> Jason.decode!()
    end
  end

  defp stop_session(session_id, opts) do
    case Registry.lookup(OptimalSystemAgent.SessionRegistry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(OptimalSystemAgent.SessionSupervisor, pid)
      _ -> :ok
    end

    TurnTrace.clear(session_id)

    # Bench sessions are measurement scaffolding, not conversations anyone will
    # resume; keep them out of the operator's session list unless asked.
    unless Keyword.get(opts, :keep_sessions, false) do
      OptimalSystemAgent.Agent.SessionPersistence.delete(session_id)
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp provider_atom(nil), do: nil
  defp provider_atom(p) when is_atom(p), do: p
  defp provider_atom(p) when is_binary(p), do: String.to_atom(p)

  # ── http ─────────────────────────────────────────────────────────────

  defp drive_http(prompt, dir, timeout_ms, opts) do
    base = opts |> Keyword.fetch!(:url) |> String.trim_trailing("/")
    headers = auth_headers(Keyword.get(opts, :token))

    # `:req_options` lets a test route the same requests through the API
    # router in-process (`plug:`) instead of a socket.
    req =
      Keyword.merge(
        [headers: headers, retry: false, receive_timeout: 30_000],
        Keyword.get(opts, :req_options, [])
      )

    secret = Keyword.get(opts, :shared_secret)

    post = fn path, body ->
      json = Jason.encode!(body)
      headers = [{"content-type", "application/json"} | signed(secret, json)]

      Req.post(
        base <> path,
        Keyword.update(req, :headers, headers, &(&1 ++ headers)) ++ [body: json]
      )
    end

    get = fn path ->
      Req.get(base <> path, Keyword.update(req, :headers, [], &(&1 ++ signed(secret, ""))))
    end

    # The daemon mints the session (bound to the workspace), so the provider
    # and permission mode can be set on it BEFORE its first turn runs.
    with {:ok, session_id} <- create_session(post, dir),
         :ok <-
           expect_ok(
             post.("/api/v1/commands/execute", %{
               command: "permission_mode overdrive",
               session_id: session_id
             })
           ),
         :ok <- maybe_set_model(post, session_id, opts),
         :ok <-
           expect_ok(
             post.("/api/v1/orchestrate", %{
               input: prompt,
               session_id: session_id,
               working_dir: dir
             })
           ) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      outcome =
        case poll_done(get, session_id, deadline) do
          {:ok, trace} -> {:ok, last_reply(get, session_id), trace}
          {:timeout, trace} -> {:timeout, trace}
        end

      # Same hygiene as the in-process runner: bench sessions stay out of the
      # daemon's session list unless asked to keep them.
      unless Keyword.get(opts, :keep_sessions, false) do
        Req.delete(
          base <> "/api/v1/sessions/#{session_id}",
          Keyword.update(req, :headers, [], &(&1 ++ signed(secret, "")))
        )
      end

      {outcome, session_id}
    else
      {:error, reason} -> {{:error, reason, nil}, nil}
    end
  end

  defp create_session(post, dir) do
    case post.("/api/v1/sessions", %{working_dir: dir}) do
      {:ok, %{status: status, body: %{"id" => id}}} when status in 200..299 and is_binary(id) ->
        {:ok, id}

      other ->
        with :ok <- expect_ok(other), do: {:error, "session create returned no id"}
    end
  end

  defp maybe_set_model(post, session_id, opts) do
    case {Keyword.get(opts, :provider), Keyword.get(opts, :model)} do
      {nil, nil} ->
        :ok

      {provider, model} ->
        body = %{provider: provider && to_string(provider), model: model}
        expect_ok(post.("/api/v1/sessions/#{session_id}/provider", body))
    end
  end

  defp poll_done(get, session_id, deadline) do
    trace =
      case get.("/api/v1/sessions/#{session_id}/trace") do
        {:ok, %{status: 200, body: %{"turn" => turn}}} -> turn
        _ -> nil
      end

    cond do
      is_map(trace) and trace["status"] != "running" ->
        {:ok, trace}

      System.monotonic_time(:millisecond) >= deadline ->
        {:timeout, trace}

      true ->
        Process.sleep(@poll_ms)
        poll_done(get, session_id, deadline)
    end
  end

  defp last_reply(get, session_id) do
    case get.("/api/v1/sessions/#{session_id}/messages") do
      {:ok, %{status: 200, body: %{"messages" => messages}}} when is_list(messages) ->
        messages
        |> Enum.filter(&(&1["role"] == "assistant" and is_binary(&1["content"])))
        |> List.last()
        |> case do
          %{"content" => content} -> content
          _ -> ""
        end

      _ ->
        ""
    end
  end

  defp expect_ok({:ok, %{status: status}}) when status in 200..299, do: :ok

  defp expect_ok({:ok, %{status: status, body: body}}),
    do: {:error, "HTTP #{status}: #{body |> inspect() |> String.slice(0, 200)}"}

  defp expect_ok({:error, e}), do: {:error, "HTTP request failed: #{Exception.message(e)}"}

  # A daemon with `OSA_SHARED_SECRET` set verifies an HMAC over every request
  # body (`Channels.HTTP.Integrity`); sign the exact bytes sent.
  defp signed(secret, _body) when secret in [nil, ""], do: []

  defp signed(secret, body) do
    ts = Integer.to_string(System.system_time(:second))
    nonce = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    mac = :crypto.mac(:hmac, :sha256, secret, ts <> "\n" <> nonce <> "\n" <> body)

    [
      {"x-osa-timestamp", ts},
      {"x-osa-nonce", nonce},
      {"x-osa-signature", Base.encode16(mac, case: :lower)}
    ]
  end

  defp auth_headers(nil), do: []
  defp auth_headers(""), do: []
  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  # ── scoring ──────────────────────────────────────────────────────────

  @doc """
  The flat metric columns of a result row, from a JSON-shaped trace summary
  (string keys) and the harness's own wall clock.
  """
  @spec metrics(map() | nil, non_neg_integer()) :: map()
  def metrics(nil, wall_ms) do
    %{
      wall_ms: wall_ms,
      turn_ms: nil,
      model_ms: nil,
      tool_ms: nil,
      approval_ms: nil,
      background_ms: nil,
      other_ms: nil,
      llm_calls: nil,
      tool_calls: nil,
      tokens_in: nil,
      tokens_out: nil,
      cache_read_tokens: nil,
      cost_usd: nil,
      retries: nil,
      wasted_steps: nil,
      wasted_ms: nil
    }
  end

  def metrics(t, wall_ms) do
    b = t["breakdown"] || %{}
    llm = t["llm"] || %{}
    tools = t["tools"] || %{}

    %{
      wall_ms: wall_ms,
      turn_ms: t["wall_ms"],
      model_ms: b["model_ms"],
      tool_ms: b["tool_ms"],
      approval_ms: b["approval_ms"],
      background_ms: b["background_ms"],
      other_ms: b["other_ms"],
      llm_calls: llm["calls"],
      tool_calls: (tools["calls"] || 0) + (get_in(t, ["background", "calls"]) || 0),
      tokens_in: llm["input_tokens"],
      tokens_out: llm["output_tokens"],
      cache_read_tokens: llm["cache_read_tokens"],
      cost_usd: llm["cost_usd"],
      retries: get_in(t, ["recoveries", "count"]),
      wasted_steps: get_in(t, ["wasted", "count"]),
      wasted_ms: get_in(t, ["wasted", "ms"])
    }
  end

  defp failed_row(status, reason) do
    Map.merge(metrics(nil, 0), %{
      status: status,
      pass: false,
      checks: [],
      error: reason,
      answer: "",
      session_id: nil,
      trace: nil
    })
  end
end
