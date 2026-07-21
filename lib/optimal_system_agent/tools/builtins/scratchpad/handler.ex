defmodule OptimalSystemAgent.Tools.Builtins.Scratchpad.Handler do
  @moduledoc """
  Validation and execution logic for `scratchpad`.

  Stages:
    * `validate/2`           — confirm action is a known value and required
      params for the chosen action are present
    * `check_permissions/2`  — always allow (the scratchpad is agent-owned and
      strictly path-scoped inside the session/team directory)
    * `execute/2`            — dispatch to `OptimalSystemAgent.Scratchpad`

  ## Coordination id resolution

  The shared directory is keyed by a coordination id, resolved in priority:

    1. explicit `team_id` arg — a team-scoped scratchpad (parity with
       `team_tasks`), letting a named team share regardless of spawn lineage;
    2. otherwise the SESSION ROOT of the caller — `Scratchpad.session_root/1`
       walks the parent chain so a spawned worker lands in the SAME directory
       as the coordinator that spawned it.

  ## Concurrency & turn boundaries (W6)

  * **Concurrent writes** — `write`/`append` are serialized through a
    cluster-wide `:global.trans` lock keyed by the coordination id (see
    `with_write_lock/2`), so many fleet nodes hammering the SAME shared dir at
    once cannot interleave/tear an append or race a directory (re)create. Reads,
    `list`, and `delete` need no lock.

  * **Turn-boundary clear** — the file-based shared scratchpad is DURABLE by
    design and is deliberately NOT wired to any new-turn clear. Only the
    in-memory provider thinking-scratchpad (`Agent.Scratchpad`) resets per turn;
    these are distinct surfaces. Therefore an in-flight workflow's shared
    entries survive across turns automatically. As defense in depth against an
    external/hostile mid-run wipe, every mutating op re-seeds the coordination
    dir (`Scratchpad.ensure_dir/1`) before writing, so coordination self-heals
    rather than crashing if the directory disappears.
  """

  alias OptimalSystemAgent.Events.Bus
  alias OptimalSystemAgent.Scratchpad
  alias OptimalSystemAgent.Tools.Builtins.Scratchpad.Constants
  alias OptimalSystemAgent.Tools.UseContext

  @needs_name ~w(write append read delete)
  @needs_content ~w(write append)

  # ── Stage 1: Input validation ─────────────────────────────────────────

  @spec validate(map(), UseContext.t() | nil) ::
          {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action} = input, _ctx) when is_binary(action) do
    cond do
      action not in Constants.valid_actions() ->
        valid = Enum.join(Constants.valid_actions(), ", ")
        {:error, "Unknown action '#{action}'. Valid actions: #{valid}", -32_602}

      action in @needs_name and not is_binary(Map.get(input, "name")) ->
        {:error, "action '#{action}' requires a string 'name'", -32_602}

      action in @needs_content and not is_binary(Map.get(input, "content")) ->
        {:error, "action '#{action}' requires string 'content'", -32_602}

      true ->
        {:ok, input}
    end
  end

  def validate(%{"action" => _}, _ctx),
    do: {:error, "action must be a string", -32_602}

  def validate(_input, _ctx),
    do: {:error, "Missing required parameter: action", -32_602}

  # ── Stage 2: Permission check ─────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t() | nil) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "write", "name" => name, "content" => content} = args, ctx) do
    id = scratchpad_id(args, ctx)

    result =
      with_write_lock(id, fn ->
        # Self-heal: re-create the coordination dir if it was wiped mid-run
        # (e.g. a turn-boundary clear) so an in-flight workflow keeps writing.
        Scratchpad.ensure_dir(id)
        Scratchpad.write(id, name, content)
      end)

    case result do
      {:ok, path} ->
        emit_activity(id, session_id(args, ctx), name, :write, byte_size(content))
        {:ok, "Wrote #{name} (#{byte_size(content)} bytes) → #{path}"}

      {:error, reason} ->
        {:ok, "Rejected: #{reason}"}
    end
  end

  def execute(%{"action" => "append", "name" => name, "content" => content} = args, ctx) do
    id = scratchpad_id(args, ctx)

    result =
      with_write_lock(id, fn ->
        Scratchpad.ensure_dir(id)
        Scratchpad.append(id, name, content)
      end)

    case result do
      {:ok, path} ->
        emit_activity(id, session_id(args, ctx), name, :append, byte_size(content))
        {:ok, "Appended #{byte_size(content)} bytes to #{name} → #{path}"}

      {:error, reason} ->
        {:ok, "Rejected: #{reason}"}
    end
  end

  def execute(%{"action" => "read", "name" => name} = args, ctx) do
    id = scratchpad_id(args, ctx)

    case Scratchpad.read(id, name) do
      {:ok, content} -> {:ok, content}
      {:error, :not_found} -> {:ok, "Entry '#{name}' not found in the shared scratchpad."}
      {:error, reason} when is_binary(reason) -> {:ok, "Rejected: #{reason}"}
      {:error, reason} -> {:ok, "Could not read '#{name}': #{inspect(reason)}"}
    end
  end

  def execute(%{"action" => "list"} = args, ctx) do
    id = scratchpad_id(args, ctx)

    case Scratchpad.list(id) do
      [] ->
        {:ok, "The shared scratchpad is empty."}

      entries ->
        lines =
          Enum.map_join(entries, "\n", fn e ->
            "- #{e.name} (#{e.size} bytes, mtime #{e.mtime})"
          end)

        {:ok, "## Shared scratchpad (#{length(entries)} entr#{if length(entries) == 1, do: "y", else: "ies"})\n\n#{lines}"}
    end
  end

  def execute(%{"action" => "delete", "name" => name} = args, ctx) do
    id = scratchpad_id(args, ctx)

    case Scratchpad.delete(id, name) do
      :ok -> {:ok, "Deleted #{name}."}
      {:error, reason} -> {:ok, "Rejected: #{reason}"}
    end
  end

  def execute(%{"action" => action}, _ctx) do
    {:ok,
     "Action '#{action}' requires additional parameters. " <>
       "Valid actions: #{Enum.join(Constants.valid_actions(), ", ")}"}
  end

  # ── Private ───────────────────────────────────────────────────────────

  # W6 — concurrency safety. Serialize MUTATING scratchpad ops (`write` /
  # `append`) so many fleet nodes writing the SAME shared coordination dir at
  # once cannot interleave/tear an append or race a directory (re)create.
  #
  # `:global.trans/2` takes a cluster-wide lock keyed by the coordination id, so
  # the serialization holds whether the fleet workers are concurrent processes
  # in one BEAM or nodes across a distributed cluster. The default (infinite)
  # retry means the lock blocks until acquired rather than aborting; the
  # `:aborted` clause is defensive (fall through to the raw op so a lock-service
  # hiccup never drops a write). Reads/list/delete need no lock — a read
  # tolerates a concurrent write and a delete is a single `File.rm`.
  defp with_write_lock(id, fun) do
    case :global.trans({{:osa_scratchpad, id}, self()}, fun) do
      :aborted -> fun.()
      result -> result
    end
  rescue
    _ -> fun.()
  catch
    _, _ -> fun.()
  end

  # Resolve the shared coordination id. An explicit `team_id` wins (team-scoped
  # sharing); otherwise the session ROOT of the caller — so a spawned worker
  # coordinates in the SAME directory as the coordinator that spawned it.
  defp scratchpad_id(args, ctx) do
    case Map.get(args, "team_id") do
      team when is_binary(team) and team != "" ->
        team

      _ ->
        Scratchpad.session_root(session_id(args, ctx))
    end
  end

  defp session_id(args, ctx) do
    Map.get(args, "__session_id__") ||
      (ctx && Map.get(ctx, :session_id)) ||
      "unknown"
  end

  # Emit a compact, best-effort activity signal so the TUI agents panel can
  # surface WHO wrote WHAT to the shared scratchpad during a fan-out. Carries no
  # file CONTENTS — only writer / entry / action / byte size. The `session_id`
  # is the shared coordination id (the session root), which is exactly the
  # `osa:session:<id>` topic the top-level TUI streams, so a worker's write shows
  # up on the coordinator's panel.
  #
  # Failure here must NEVER fail the scratchpad write, so the whole thing is
  # wrapped and swallowed. The emit fn is an injectable seam (`:scratchpad_emit_fun`)
  # so a test can force it to raise and confirm the write still succeeds.
  defp emit_activity(coordination_id, writer, entry, action, bytes) do
    emit = Application.get_env(:optimal_system_agent, :scratchpad_emit_fun, &Bus.emit/2)

    emit.(:system_event, %{
      event: :scratchpad_activity,
      session_id: coordination_id,
      agent: writer,
      entry: entry,
      action: action,
      bytes: bytes
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
