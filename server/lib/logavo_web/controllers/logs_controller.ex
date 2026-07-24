defmodule LogavoWeb.LogsController do
  @moduledoc """
  検索 API（spec 3.2 / Phase 3）。

      GET /api/logs?source=backend-api&level=error&q=timeout&from=...&to=...&limit=100

  source / level / キーワード(q) / 期間(from,to) で `log_entries` を絞り込み、
  新しい順（id 降順）に JSON で返す。認証は localhost 前提のため省略（spec 5）。

  server-schema の `Logavo.Logs` 生成 API 名に密結合しないよう、参照専用の
  読み取りクエリは `LogEntry` スキーマと `Logavo.Repo` に対して直接組み立てる。
  必要な列だけを `select` するため、`inserted_at` 等の Ecto 型に依存しない。
  """
  use LogavoWeb, :controller

  import Ecto.Query

  alias Logavo.Repo
  alias Logavo.Logs.LogEntry

  @default_limit 100
  @max_limit 1000

  def index(conn, params) do
    entries =
      params
      |> build_query()
      |> Repo.all()
      |> Enum.map(&to_entry/1)

    json(conn, %{entries: entries, count: length(entries)})
  end

  # --- クエリ組み立て（spec 6: Ecto クエリ組み立ての学習） --------------
  defp build_query(params) do
    LogEntry
    |> filter_source(params)
    |> filter_level(params)
    |> filter_keyword(params)
    |> filter_from(params)
    |> filter_to(params)
    |> order_by([le], desc: le.id)
    |> limit(^parse_limit(params))
    |> select([le], %{
      id: le.id,
      timestamp: le.timestamp,
      source: le.source,
      level: le.level,
      message: le.message,
      raw: le.raw,
      meta: le.meta
    })
  end

  defp filter_source(query, %{"source" => source}) when is_binary(source) and source != "" do
    where(query, [le], le.source == ^source)
  end

  defp filter_source(query, _params), do: query

  defp filter_level(query, %{"level" => level}) when is_binary(level) and level != "" do
    where(query, [le], le.level == ^level)
  end

  defp filter_level(query, _params), do: query

  # ASSUMPTION: ローカル用途のためキーワードのワイルドカード(%,_)はエスケープせず
  # そのまま LIKE パターンに埋める（開発者が意図的に部分一致を効かせられる）。
  # SQLite の LIKE は ASCII について既定で大文字小文字を区別しない。message と
  # raw の双方を対象にし、生ログしか手掛かりが無い行も拾えるようにする。
  defp filter_keyword(query, %{"q" => q}) when is_binary(q) and q != "" do
    pattern = "%" <> q <> "%"
    where(query, [le], like(le.message, ^pattern) or like(le.raw, ^pattern))
  end

  defp filter_keyword(query, _params), do: query

  # 期間は timestamp(ISO8601 文字列)の辞書順比較で絞り込む（同一フォーマットの
  # UTC ISO8601 は辞書順が時系列順と一致する）。ただし保存値はミリ秒付き
  # （"...00:00:00.000Z"）で、境界指定はミリ秒無し（"...00:00:00Z"）で来ることが
  # ある。素朴に "Z" 付き文字列同士で比較すると、同一時刻でも保存値の '.' が
  # 境界の 'Z'(0x5A) より小さいため境界のログを取りこぼす。そこで境界値を精度
  # 単位の端に正規化してから比較する:
  #   * from は下端 = 末尾 "Z" を落とした接頭辞（その精度の先頭を含む）
  #   * to   は上端 = 末尾 "Z" を落として高位センチネル "~" を付す（その精度の末尾まで含む）
  # "~"(0x7E) は保存値が取りうる文字（数字 / '.' / ':' / 'T' / 'Z'(0x5A) 等）より
  # 大きいため、当該精度単位に属する全ミリ秒値が上端以下に収まり、次の単位は
  # 確実に除外される（SQLite の TEXT はバイト順比較で Elixir の文字列比較と一致）。
  defp filter_from(query, %{"from" => from}) when is_binary(from) and from != "" do
    where(query, [le], le.timestamp >= ^lower_bound(from))
  end

  defp filter_from(query, _params), do: query

  defp filter_to(query, %{"to" => to}) when is_binary(to) and to != "" do
    where(query, [le], le.timestamp <= ^upper_bound(to))
  end

  defp filter_to(query, _params), do: query

  defp lower_bound(value), do: String.trim_trailing(value, "Z")
  defp upper_bound(value), do: String.trim_trailing(value, "Z") <> "~"

  defp parse_limit(%{"limit" => limit}) do
    case Integer.parse(to_string(limit)) do
      {n, _} when n > 0 -> min(n, @max_limit)
      _ -> @default_limit
    end
  end

  defp parse_limit(_params), do: @default_limit

  # meta は JSON 文字列で保存されているので、レスポンスでは復元して返す
  # （spec 2.1 の meta オブジェクト）。復元不能なら文字列のまま返し情報を失わない。
  defp to_entry(row) do
    %{
      id: row.id,
      timestamp: row.timestamp,
      source: row.source,
      level: row.level,
      message: row.message,
      raw: row.raw,
      meta: decode_meta(row.meta)
    }
  end

  defp decode_meta(nil), do: nil

  defp decode_meta(meta) when is_binary(meta) do
    case Jason.decode(meta) do
      {:ok, decoded} -> decoded
      {:error, _} -> meta
    end
  end

  defp decode_meta(meta), do: meta
end
