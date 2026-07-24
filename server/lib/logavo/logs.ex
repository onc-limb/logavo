defmodule Logavo.Logs do
  @moduledoc """
  ログ収集・検索・集計のコンテキスト。

  - `Logavo.Logs.LogEntry`  : 正規化済みログ行（docs/spec.md 2.1 / 2.3）
  - `Logavo.Logs.ProxyRequest` : agent-proxy が計測した HTTP メトリクス（docs/spec.md 2.2）

  プロキシメトリクスは level を持たないため log_entries とは別テーブルに
  分離し、遅い順・ステータス別集計を専用インデックスで効率化する。
  """
  import Ecto.Query, warn: false

  alias Logavo.Repo
  alias Logavo.Logs.LogEntry
  alias Logavo.Logs.ProxyRequest

  @default_limit 100

  ## --- LogEntry ---------------------------------------------------------

  @doc """
  ログを新しい順に取得する。

  オプション（keyword / map、いずれも atom キー）:
    * `:source` - source の完全一致
    * `:level`  - level の完全一致
    * `:q`      - message / raw の部分一致キーワード
    * `:from`   - timestamp >= from（ISO8601 文字列比較）
    * `:to`     - timestamp <= to（ISO8601 文字列比較）
    * `:limit`  - 取得件数上限（既定 #{@default_limit}）
  """
  def list_log_entries(opts \\ []) do
    LogEntry
    |> log_filter_source(opts[:source])
    |> log_filter_level(opts[:level])
    |> log_filter_keyword(opts[:q])
    |> log_filter_from(opts[:from])
    |> log_filter_to(opts[:to])
    |> order_by([l], desc: l.timestamp, desc: l.id)
    |> limit(^(opts[:limit] || @default_limit))
    |> Repo.all()
  end

  @doc "id でログを取得する（存在しなければ raise）。"
  def get_log_entry!(id), do: Repo.get!(LogEntry, id)

  @doc "ログ 1 件を作成する。"
  def create_log_entry(attrs \\ %{}) do
    %LogEntry{}
    |> LogEntry.changeset(attrs)
    |> Repo.insert()
  end

  @doc "ログ用 changeset を返す（フォーム/検証用）。"
  def change_log_entry(%LogEntry{} = log_entry, attrs \\ %{}) do
    LogEntry.changeset(log_entry, attrs)
  end

  @doc """
  複数ログをトランザクションで一括作成する。

  1 件でも検証に失敗したらロールバックし
  `{:error, index, changeset}` を返す。成功時は `{:ok, entries}`。
  """
  def create_log_entries(entries) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {attrs, idx}, multi ->
      Ecto.Multi.insert(multi, idx, LogEntry.changeset(%LogEntry{}, attrs))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, results} ->
        entries_in_order =
          results
          |> Enum.sort_by(fn {idx, _entry} -> idx end)
          |> Enum.map(fn {_idx, entry} -> entry end)

        {:ok, entries_in_order}

      {:error, idx, changeset, _changes} ->
        {:error, idx, changeset}
    end
  end

  ## --- ProxyRequest -----------------------------------------------------

  @doc """
  プロキシリクエストを取得する。

  オプション:
    * `:status` - ステータスの完全一致
    * `:order`  - `:recent`（既定）または `:slowest`
    * `:limit`  - 取得件数上限（既定 #{@default_limit}）
  """
  def list_proxy_requests(opts \\ []) do
    ProxyRequest
    |> proxy_filter_status(opts[:status])
    |> proxy_order(opts[:order] || :recent)
    |> limit(^(opts[:limit] || @default_limit))
    |> Repo.all()
  end

  @doc "レイテンシの大きい順（遅い順）に取得する。"
  def list_slowest_proxy_requests(limit \\ @default_limit) do
    list_proxy_requests(order: :slowest, limit: limit)
  end

  @doc "ステータス別の件数を集計する（`%{status: _, count: _}` のリスト）。"
  def proxy_status_counts do
    ProxyRequest
    |> group_by([p], p.status)
    |> select([p], %{status: p.status, count: count(p.id)})
    |> order_by([p], asc: p.status)
    |> Repo.all()
  end

  @doc "プロキシリクエスト 1 件を作成する。"
  def create_proxy_request(attrs \\ %{}) do
    %ProxyRequest{}
    |> ProxyRequest.changeset(attrs)
    |> Repo.insert()
  end

  @doc "プロキシ用 changeset を返す。"
  def change_proxy_request(%ProxyRequest{} = proxy_request, attrs \\ %{}) do
    ProxyRequest.changeset(proxy_request, attrs)
  end

  ## --- private: LogEntry filters ----------------------------------------

  defp log_filter_source(query, source) when source in [nil, ""], do: query
  defp log_filter_source(query, source), do: where(query, [l], l.source == ^source)

  defp log_filter_level(query, level) when level in [nil, ""], do: query
  defp log_filter_level(query, level), do: where(query, [l], l.level == ^level)

  defp log_filter_keyword(query, q) when q in [nil, ""], do: query

  defp log_filter_keyword(query, q) do
    pattern = "%#{q}%"
    where(query, [l], like(l.message, ^pattern) or like(l.raw, ^pattern))
  end

  defp log_filter_from(query, from) when from in [nil, ""], do: query
  defp log_filter_from(query, from), do: where(query, [l], l.timestamp >= ^from)

  defp log_filter_to(query, to) when to in [nil, ""], do: query
  defp log_filter_to(query, to), do: where(query, [l], l.timestamp <= ^to)

  ## --- private: ProxyRequest filters ------------------------------------

  defp proxy_filter_status(query, nil), do: query
  defp proxy_filter_status(query, ""), do: query
  defp proxy_filter_status(query, status), do: where(query, [p], p.status == ^status)

  defp proxy_order(query, :slowest), do: order_by(query, [p], desc: p.latency_ms, desc: p.id)
  defp proxy_order(query, _recent), do: order_by(query, [p], desc: p.timestamp, desc: p.id)
end
