defmodule OptimalSystemAgent.Store.Message do
  @moduledoc """
  Ecto schema for persisted messages.

  Messages are written to SQLite on every agent interaction, providing
  persistent, queryable conversation history across all sessions.

  All text fields are validated as UTF-8 before insertion to prevent
  multi-byte character mangling (Japanese, emoji, CJK).
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
    |> validate_utf8(:content)
  end

  # Validate that a string field contains only valid UTF-8.
  # Invalid bytes are replaced rather than rejecting the entire message,
  # because losing a message is worse than losing a few garbled bytes.
  defp validate_utf8(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value when is_binary(value) ->
        if String.valid?(value) do
          changeset
        else
          cleaned = sanitize_utf8(value)
          put_change(changeset, field, cleaned)
        end

      _other ->
        changeset
    end
  end

  defp sanitize_utf8(bin) do
    case :unicode.characters_to_binary(bin, :utf8, :utf8) do
      result when is_binary(result) -> result
      {:error, good, _bad} -> good
      {:incomplete, good, _rest} -> good
    end
  end
end
