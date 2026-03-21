defmodule OptimalSystemAgent.Tools.Builtins.PeerClaimRegion do
  @moduledoc """
  Region Claim Tool — claim an exclusive line range in a file before editing.

  Agents working concurrently on the same file call this tool to register their
  intent to modify a specific region. The system rejects overlapping claims,
  preventing silent conflicts.

  ## Workflow

    1. Before editing lines N–M in a file, call `peer_claim_region` with
       `action: claim`.
    2. Proceed with the edit. Call `touch` periodically for long-running edits
       (resets the 10-minute inactivity timer).
    3. After saving the file, call `peer_claim_region` with `action: release`.
    4. Use `action: list` to see all current claims on a file.
  """
  use OptimalSystemAgent.Tools.Behaviour

  alias OptimalSystemAgent.FileLocking.RegionLock

  @impl true
  def name, do: "peer_claim_region"

  @impl true
  def description do
    "Claim an exclusive line range in a file before editing. " <>
      "Prevents concurrent agents from editing the same lines. " <>
      "Always claim before editing, release after saving."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "required" => ["action", "file_path"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["claim", "release", "list", "touch"],
          "description" =>
            "claim: lock a region, release: free it, list: see all claims, touch: reset expiry timer"
        },
        "file_path" => %{
          "type" => "string",
          "description" => "Absolute path to the file."
        },
        "start_line" => %{
          "type" => "integer",
          "description" => "First line of the region (1-indexed, inclusive). Required for claim."
        },
        "end_line" => %{
          "type" => "integer",
          "description" => "Last line of the region (inclusive). Required for claim."
        },
        "region_id" => %{
          "type" => "string",
          "description" => "Region ID returned by a prior claim. Required for release/touch."
        }
      }
    }
  end

  @impl true
  def safety, do: :write_safe

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  @impl true
  def execute(%{"action" => "claim", "file_path" => file_path} = args) do
    agent_id = Map.get(args, "__session_id__", "unknown")

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

  def execute(%{"action" => "release", "file_path" => file_path, "region_id" => region_id} = args) do
    agent_id = Map.get(args, "__session_id__", "unknown")
    RegionLock.release_region(agent_id, file_path, region_id)
    {:ok, "Region #{region_id} released."}
  end

  def execute(%{"action" => "list", "file_path" => file_path}) do
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

  def execute(%{"action" => "touch", "region_id" => region_id} = args) do
    agent_id = Map.get(args, "__session_id__", "unknown")
    RegionLock.touch_region(agent_id, region_id)
    {:ok, "Region #{region_id} timer reset."}
  end

  def execute(%{"action" => "release"}) do
    {:error, "Missing required parameter: region_id is required for release."}
  end

  def execute(_) do
    {:error, "Invalid parameters. Required: action (claim|release|list|touch), file_path."}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

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
