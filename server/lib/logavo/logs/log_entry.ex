defmodule Logavo.Logs.LogEntry do
  @moduledoc """
  正規化済みログ 1 行を表すスキーマ（docs/spec.md 2.1 / 2.3）。

  `meta` は JSON 文字列カラムとして永続化する。changeset に map/list を
  渡した場合は `Jason` で自動的にエンコードし、既に文字列であればそのまま扱う。
  """
  use Ecto.Schema
  import Ecto.Changeset

  # docs/spec.md 2.1: level は debug / info / warn / error / unknown の enum。
  @levels ~w(debug info warn error unknown)

  @type t :: %__MODULE__{}

  schema "log_entries" do
    field :timestamp, :string
    field :source, :string
    field :level, :string
    field :message, :string
    field :raw, :string
    field :meta, :string

    timestamps(updated_at: false)
  end

  @doc """
  取り込み用 changeset。`level` は enum 検証を行い、`raw` は必ず要求する
  （パース失敗時もデータを失わないため）。
  """
  def changeset(log_entry, attrs) do
    log_entry
    |> cast(encode_meta(attrs), [:timestamp, :source, :level, :message, :raw, :meta])
    |> validate_required([:timestamp, :source, :level, :message, :raw])
    |> validate_inclusion(:level, @levels)
  end

  @doc "受け付ける level の一覧を返す。"
  def levels, do: @levels

  # meta が map/list で渡ってきたら JSON 文字列へ変換する。
  # 文字列 / nil / キー未指定はそのまま通す。atom キー・string キーの両方に対応。
  defp encode_meta(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :meta) -> Map.update!(attrs, :meta, &do_encode_meta/1)
      Map.has_key?(attrs, "meta") -> Map.update!(attrs, "meta", &do_encode_meta/1)
      true -> attrs
    end
  end

  defp encode_meta(attrs), do: attrs

  defp do_encode_meta(nil), do: nil
  defp do_encode_meta(value) when is_binary(value), do: value
  defp do_encode_meta(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp do_encode_meta(value), do: value
end
