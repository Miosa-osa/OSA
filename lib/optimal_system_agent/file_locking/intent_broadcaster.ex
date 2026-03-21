defmodule OptimalSystemAgent.FileLocking.IntentBroadcaster do
  @moduledoc """
  Edit Intent Broadcasting — notify all agents working on the same file when
  one agent starts or changes its editing intent for that file.

  Prevents surprise conflicts by making in-progress edits visible before they
  land. Agents subscribe to a file-keyed PubSub topic and receive notifications
  when any other agent broadcasts intent on that file.

  ## PubSub topics

    * `\"osa:file_intent:<file_path>\"` — all intent events for a file

  ## ETS storage

  Active file subscriptions are tracked in `:osa_file_subscriptions` (bag):
  `{file_path, agent_id}`. This lets the broadcaster know who to notify and lets
  agents query who else is editing a file.

  Intent events are also stored in `:osa_file_intents` (set) keyed by
  `{file_path, agent_id}` — one record per agent per file, overwritten on each
  broadcast. This provides a snapshot of current intents for late-joining agents.
  """

  require Logger

  @subscriptions_table :osa_file_subscriptions
  @intents_table :osa_file_intents

  # ---------------------------------------------------------------------------
  # ETS bootstrap
  # ---------------------------------------------------------------------------

  @doc "Create ETS tables for intent broadcasting. Called at application start."
  def init_tables do
    :ets.new(@subscriptions_table, [:named_table, :public, :bag])
    :ets.new(@intents_table, [:named_table, :public, :set])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Broadcast edit intent for a file.

  Publishes a `{:file_intent, intent_event}` message on the file's PubSub topic.
  All subscribed agents receive the notification immediately.

  `intent_description` is a human-readable string describing what the agent
  intends to do, e.g., `\"refactoring lines 40–80\"` or `\"claimed lines 10–30\"`.

  This is also called internally by `RegionLock` when a region is claimed or
  released.
  """
  @spec broadcast_intent(
          agent_id :: String.t(),
          file_path :: String.t(),
          intent_description :: String.t()
        ) :: :ok
  def broadcast_intent(agent_id, file_path, intent_description) do
    event = %{
      agent_id: agent_id,
      file_path: file_path,
      intent: intent_description,
      at: DateTime.utc_now()
    }

    # Persist latest intent snapshot for this agent+file pair
    :ets.insert(@intents_table, {{file_path, agent_id}, event})

    # Broadcast to all subscribers on this file
    Phoenix.PubSub.broadcast(
      OptimalSystemAgent.PubSub,
      "osa:file_intent:#{file_path}",
      {:file_intent, event}
    )

    Logger.debug("[IntentBroadcaster] #{agent_id} on #{file_path}: #{intent_description}")

    :ok
  rescue
    e ->
      Logger.warning("[IntentBroadcaster] broadcast failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Subscribe an agent to intent notifications for a file.

  After subscribing, the agent's process will receive `{:file_intent, event}`
  messages whenever any agent broadcasts intent on this file.

  Records the subscription in ETS so other agents can discover who is editing
  the same file via `subscribers_for/1`.
  """
  @spec subscribe_to_file(agent_id :: String.t(), file_path :: String.t()) :: :ok
  def subscribe_to_file(agent_id, file_path) do
    Phoenix.PubSub.subscribe(OptimalSystemAgent.PubSub, "osa:file_intent:#{file_path}")

    # Record subscription in ETS — use a composite key to make unsubscribe precise
    # The bag stores {file_path, agent_id}; duplicates from re-subscription are
    # harmless because subscribers_for/1 calls Enum.uniq on agent_ids.
    :ets.insert(@subscriptions_table, {file_path, agent_id})

    Logger.debug("[IntentBroadcaster] #{agent_id} subscribed to #{file_path}")
    :ok
  rescue
    e ->
      Logger.warning("[IntentBroadcaster] subscribe failed: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Unsubscribe an agent from intent notifications for a file.

  Also removes the subscription record from ETS.
  """
  @spec unsubscribe_from_file(agent_id :: String.t(), file_path :: String.t()) :: :ok
  def unsubscribe_from_file(agent_id, file_path) do
    Phoenix.PubSub.unsubscribe(OptimalSystemAgent.PubSub, "osa:file_intent:#{file_path}")
    :ets.match_delete(@subscriptions_table, {file_path, agent_id})

    # Clear intent snapshot for this agent on this file
    :ets.delete(@intents_table, {file_path, agent_id})

    Logger.debug("[IntentBroadcaster] #{agent_id} unsubscribed from #{file_path}")
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Return all agent IDs currently subscribed to a file's intent notifications.

  Reads from ETS — no round-trip to PubSub.
  """
  @spec subscribers_for(file_path :: String.t()) :: [String.t()]
  def subscribers_for(file_path) do
    :ets.lookup(@subscriptions_table, file_path)
    |> Enum.map(fn {_, agent_id} -> agent_id end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  @doc """
  Return the current intent snapshots for all agents editing a file.

  Returns a list of intent event maps — one per agent that has broadcast intent
  on this file and not yet unsubscribed.
  """
  @spec current_intents_for(file_path :: String.t()) :: [map()]
  def current_intents_for(file_path) do
    :ets.match_object(@intents_table, {{file_path, :_}, :_})
    |> Enum.map(fn {_, event} -> event end)
    |> Enum.sort_by(& &1.at, DateTime)
  rescue
    _ -> []
  end
end
