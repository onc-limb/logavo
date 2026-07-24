defmodule Logavo.Logs.ProxyRequest do
  @moduledoc """
  agent-proxy が計測した HTTP リクエスト 1 件（docs/spec.md 2.2）。

  プロキシメトリクスは level を持たないため `Logavo.Logs.LogEntry` とは
  別テーブル（proxy_requests）に分離し、method/path/status/latency_ms/
  req_bytes/res_bytes/timestamp を専用カラムで保持する。
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "proxy_requests" do
    field :method, :string
    field :path, :string
    field :status, :integer
    field :latency_ms, :integer
    field :req_bytes, :integer, default: 0
    field :res_bytes, :integer, default: 0
    field :timestamp, :string

    timestamps(updated_at: false)
  end

  @doc """
  取り込み用 changeset。status は HTTP ステータスの範囲、サイズ・レイテンシは
  非負であることを検証する。method は任意メソッドを許容するため必須のみ。
  """
  def changeset(proxy_request, attrs) do
    proxy_request
    |> cast(attrs, [:method, :path, :status, :latency_ms, :req_bytes, :res_bytes, :timestamp])
    |> validate_required([:method, :path, :status, :latency_ms, :timestamp])
    |> validate_number(:status, greater_than_or_equal_to: 100, less_than: 600)
    |> validate_number(:latency_ms, greater_than_or_equal_to: 0)
    |> validate_number(:req_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:res_bytes, greater_than_or_equal_to: 0)
  end
end
