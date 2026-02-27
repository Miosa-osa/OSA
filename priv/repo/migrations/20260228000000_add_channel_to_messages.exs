defmodule OptimalSystemAgent.Store.Repo.Migrations.AddChannelToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :channel, :string
    end

    create index(:messages, [:channel], name: :messages_channel_index)
    create index(:messages, [:session_id, :channel], name: :messages_session_id_channel_index)
  end
end
