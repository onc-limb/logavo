defmodule Logavo.Repo.Migrations.CreateProxyRequests do
  use Ecto.Migration

  # docs/spec.md 2.2 の HTTP リクエストログ（agent-proxy が生成）専用テーブル。
  # プロキシメトリクスは level を持たないため log_entries とは分離し、
  # method/path/status/latency_ms/req_bytes/res_bytes/timestamp を
  # 専用カラムで持つことでソート・集計を効率化する。
  def change do
    create table(:proxy_requests) do
      add :method, :string, null: false
      add :path, :text, null: false
      add :status, :integer, null: false
      add :latency_ms, :integer, null: false
      add :req_bytes, :integer, null: false, default: 0
      add :res_bytes, :integer, null: false, default: 0
      # timestamp は ISO8601 文字列（log_entries と同様、文字列比較で範囲検索）
      add :timestamp, :string, null: false

      timestamps(updated_at: false)
    end

    # 遅い順（latency_ms）・ステータス別集計（status）・時系列（timestamp）を高速化。
    create index(:proxy_requests, [:latency_ms])
    create index(:proxy_requests, [:status])
    create index(:proxy_requests, [:timestamp])
  end
end
