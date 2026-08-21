defmodule AshReplicant.TestRepo.Migrations.AddAppendMessageFixtures do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:order_events) do
      add(:message_prefix, :text)
      add(:message_content, :binary)
    end
  end
end
