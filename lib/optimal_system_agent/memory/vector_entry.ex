defmodule OptimalSystemAgent.Memory.VectorEntry do
  @moduledoc """
  Ecto schema for the `memory_vectors` table — durable persistence for
  `Memory.Search` embedding vectors.

  One row per memory entry `id`. `content_hash` is `:erlang.phash2/1` of the
  embedded text (matching the hash `Memory.Search`'s ETS cache already used),
  so a changed memory's stale vector is detected and re-embedded rather than
  served stale. `embedding` is a JSON-encoded float array (see
  `Memory.Search` moduledoc for why this project stores vectors as a plain
  column rather than via a `sqlite-vec` extension).

  This schema is intentionally private plumbing for `Memory.Search` — no
  other module should reference `VectorEntry` or the `memory_vectors` table
  directly.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "memory_vectors" do
    field(:content_hash, :integer)
    field(:embedding, :string)
    field(:dim, :integer)
    field(:model, :string)
    field(:created_at, :string)
    field(:updated_at, :string)
  end

  @required_fields [:id, :content_hash, :embedding, :dim, :created_at, :updated_at]
  @optional_fields [:model]

  @doc "Build a changeset for inserting or updating a persisted vector row."
  def changeset(vector \\ %__MODULE__{}, attrs) do
    vector
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
