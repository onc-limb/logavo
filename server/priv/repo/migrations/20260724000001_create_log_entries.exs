defmodule Logavo.Repo.Migrations.CreateLogEntries do
  use Ecto.Migration

  # docs/spec.md 2.3 のテーブル定義に対応。
  # timestamp は ISO8601 文字列としてそのまま格納し、
  # 文字列比較で期間フィルタ・並べ替えできるよう索引を張る。
  def change do
    create table(:log_entries) do
      add :timestamp, :string, null: false
      add :source, :string, null: false
      add :level, :string, null: false
      add :message, :text, null: false
      add :raw, :text, null: false
      # meta は JSON 文字列（NULL 許容）
      add :meta, :text

      # spec 2.3 は inserted_at のみ。updated_at は持たない。
      timestamps(updated_at: false)
    end

    create index(:log_entries, [:timestamp])
    create index(:log_entries, [:source, :level])
  end
end
