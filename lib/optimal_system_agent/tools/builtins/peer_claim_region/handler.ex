defmodule OptimalSystemAgent.Tools.Builtins.PeerClaimRegion.Handler do
  @moduledoc """
  Validation, permission, and execution logic for `peer_claim_region`.

  Split mirrors the structured-layout pattern:
    * `validate/2`          — type-check input shape
    * `check_permissions/2` — deny read-only contexts
    * `execute/2`           — dispatch to `OptimalSystemAgent.FileLocking.RegionLock`
  """

  alias OptimalSystemAgent.FileLocking.RegionLock
  alias OptimalSystemAgent.Tools.UseContext

  # ── Stage 1: Validate ─────────────────────────────────────────────────

  @spec validate(map(), UseContext.t()) :: {:ok, map()} | {:error, String.t(), integer()}
  def validate(%{"action" => action, "file_path" => _} = input, _ctx)
      when action in ["claim", "release", "list", "touch"] do
    {:ok, input}
  end

  def validate(%{"action" => action}, _ctx)
      when action in ["claim", "release", "list", "touch"] do
    {:error, "Missing required parameter: file_path", -32_602}
  end

  def validate(%{"action" => other}, _ctx) do
    {:error, "Invalid action '#{other}'. Use: claim, release, list, touch", -32_602}
  end

  def validate(_, _ctx),
    do: {:error, "Missing required parameters: action, file_path", -32_602}

  # ── Stage 2: Permissions ──────────────────────────────────────────────

  @spec check_permissions(map(), UseContext.t()) ::
          {:allow, map()} | {:deny, String.t()}
  def check_permissions(_input, %UseContext{read_only_request?: true}) do
    {:deny, "Access denied: peer_claim_region is not available in read-only mode"}
  end

  def check_permissions(input, _ctx), do: {:allow, input}

  # ── Stage 3: Execute ──────────────────────────────────────────────────

  @spec execute(map(), UseContext.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(%{"action" => "claim", "file_path" => file_path} = args, ctx) do
    agent_id = ctx.session_id || Map.get(args, "__session_id__", "unknown")

    with {:ok, start_line} <- fetch_integer(args, "start_line"),
         {:ok, end_line} <- fetch_integer(args, "end_line") do
      if start_line > end_line do
        {:error, "start_line must be <= end_line"}
      else
        case RegionLock.claim_region(agent_id, file_path, start_line, end_line) do
          {:ok, region_id} ->
            {:ok,
             "Region claimed. ID: `#{region_id}`\n" <>
               "File: #{file_path} lines #{start_line}–#{end_line}\n" <>
               "Remember to call `peer_claim_region` with action `release` after saving."}

          {:conflict, holder} ->
            {:ok,
             "Conflict: lines #{start_line}–#{end_line} in #{file_path} are claimed by agent " <>
               "#{holder.agent_id} (region #{holder.region_id}, " <>
               "lines #{holder.start_line}–#{holder.end_line}). " <>
               "Wait for them to release or negotiate a non-overlapping range."}
        end
      end
    end
  end

  def execute(
        %{"action" => "release", "file_path" => file_path, "region_id" => region_id} = args,
        ctx
      ) do
    agent_id = ctx.session_id || Map.get(args, "__session_id__", "unknown")
    RegionLock.release_region(agent_id, file_path, region_id)
    {:ok, "Region #{region_id} released."}
  end

  def execute(%{"action" => "release"}, _ctx) do
    {:error, "Missing required parameter: region_id is required for 'release' action."}
  end

  def execute(%{"action" => "list", "file_path" => file_path}, _ctx) do
    claims = RegionLock.list_claims(file_path)

    if claims == [] do
      {:ok, "No active region claims on #{file_path}."}
    else
      lines =
        Enum.map_join(claims, "\n", fn c ->
          "- `#{c.region_id}` #{c.agent_id}: lines #{c.start_line}–#{c.end_line}" <>
            " (claimed #{Calendar.strftime(c.claimed_at, "%H:%M:%S")})"
        end)

      {:ok, "## Active region claims on #{file_path}\n\n#{lines}"}
    end
  end

  def execute(%{"action" => "touch", "region_id" => region_id} = args, ctx) do
    agent_id = ctx.session_id || Map.get(args, "__session_id__", "unknown")
    RegionLock.touch_region(agent_id, region_id)
    {:ok, "Region #{region_id} timer reset."}
  end

  def execute(%{"action" => "touch"}, _ctx) do
    {:error, "Missing required parameter: region_id is required for 'touch' action."}
  end

  # ── Private ───────────────────────────────────────────────────────────

  defp fetch_integer(args, key) do
    case Map.get(args, key) do
      nil ->
        {:error, "Missing required parameter: #{key}"}

      v when is_integer(v) ->
        {:ok, v}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _ -> {:error, "#{key} must be an integer"}
        end

      _ ->
        {:error, "#{key} must be an integer"}
    end
  end
end
