defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateMemoryVectors do
  use Ecto.Migration

  @moduledoc """
  Durable persistence for `Memory.Search` embedding vectors (P1 hybrid-RAG
  gap-fix: was an ephemeral ETS-only cache — lost every restart, forcing a
  full re-embed of every memory on boot).

  ## Why a plain BLOB/TEXT column table instead of `sqlite-vec`

  This project's SQLite access is `ecto_sqlite3` / `exqlite` (see
  `OptimalSystemAgent.Store.Repo`, `adapter: Ecto.Adapters.SQLite3`).
  `exqlite` links a vendored/precompiled SQLite via its NIF and does not
  expose a way to `load_extension` an arbitrary native extension like
  `sqlite-vec` from application code — wiring that up would mean patching
  `exqlite`'s NIF build itself, well outside this migration's scope. So
  instead of a vector index extension, embeddings are stored as a JSON-encoded
  float array in a `:text` column and cosine similarity is computed in
  Elixir (`Memory.Search.cosine_similarity/2`, unchanged) after being warmed
  into the existing ETS cache. OSA's memory table is small (hundreds—low
  thousands of rows), so an O(n) in-memory cosine scan is not a bottleneck;
  this is the same pragmatic trade-off already documented in
  `Memory.Search`'s moduledoc.

  ## Idempotency

  Uses `create_if_not_exists` / `create ... if not exists` so this migration
  is safe to re-run against a DB where the table already exists (matches the
  house style used for defensive migrations elsewhere in this project).
  """

  def change do
    create_if_not_exists table(:memory_vectors, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      # erlang.phash2/1 of the embedded content — same hashing Memory.Search's
      # ETS cache already used, kept identical so a row and its ETS mirror are
      # always comparable without a re-embed just to normalize hash format.
      add :content_hash, :integer, null: false
      # JSON-encoded [float, ...] embedding vector.
      add :embedding, :text, null: false
      add :dim, :integer, null: false
      add :model, :string
      add :created_at, :string, null: false
      add :updated_at, :string, null: false
    end

    create_if_not_exists index(:memory_vectors, [:content_hash])
  end
end
