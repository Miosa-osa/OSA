defmodule OptimalSystemAgent.Store.Message do
  @moduledoc """
  Ecto schema for persisted messages.

  Messages are written to SQLite on every agent interaction, providing
  persistent, queryable conversation history across all sessions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    field(:session_id, :string)
    field(:role, :string)
    field(:content, :string)
    field(:tool_calls, :map)
    field(:tool_call_id, :string)
    field(:signal_mode, :string)
    field(:signal_weight, :float)
    field(:token_count, :integer)
    field(:channel, :string)
    field(:metadata, :map, default: %{})
    timestamps()
  end

  @required_fields [:session_id, :role]
  @optional_fields [
    :content,
    :tool_calls,
    :tool_call_id,
    :signal_mode,
    :signal_weight,
    :token_count,
    :channel,
    :metadata
  ]
  @valid_roles ["user", "assistant", "tool", "system"]

  @doc "Create a changeset for inserting a message."
  def changeset(message \\ %__MODULE__{}, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, @valid_roles)
  end
end
