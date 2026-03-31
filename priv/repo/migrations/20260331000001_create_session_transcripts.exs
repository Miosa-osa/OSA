defmodule OptimalSystemAgent.Store.Repo.Migrations.CreateSessionTranscripts do
  use Ecto.Migration

  def up do
    create table(:session_transcripts) do
      add :session_id, :string, null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :tool_name, :string
      add :tokens, :integer, default: 0
      timestamps()
    end

    create index(:session_transcripts, [:session_id])
    create index(:session_transcripts, [:inserted_at])

    # FTS5 virtual table for full-text search across session transcripts.
    # content= points to the real table; content_rowid= maps to its id column.
    execute """
    CREATE VIRTUAL TABLE IF NOT EXISTS session_transcripts_fts USING fts5(
      content,
      tool_name,
      content='session_transcripts',
      content_rowid='id'
    )
    """

    # Triggers to keep the FTS index in sync with the real table
    execute """
    CREATE TRIGGER IF NOT EXISTS session_transcripts_ai AFTER INSERT ON session_transcripts BEGIN
      INSERT INTO session_transcripts_fts(rowid, content, tool_name)
      VALUES (new.id, new.content, new.tool_name);
    END
    """

    execute """
    CREATE TRIGGER IF NOT EXISTS session_transcripts_ad AFTER DELETE ON session_transcripts BEGIN
      INSERT INTO session_transcripts_fts(session_transcripts_fts, rowid, content, tool_name)
      VALUES ('delete', old.id, old.content, old.tool_name);
    END
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS session_transcripts_ad"
    execute "DROP TRIGGER IF EXISTS session_transcripts_ai"
    execute "DROP TABLE IF EXISTS session_transcripts_fts"
    drop_if_exists table(:session_transcripts)
  end
end
