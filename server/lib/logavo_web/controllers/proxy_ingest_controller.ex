defmodule LogavoWeb.ProxyIngestController do
  @moduledoc """
  agent-proxy 用のメトリクス取り込みエンドポイント (`POST /api/proxy`)。

  spec 2.2 の HTTP リクエストログ形式（meta に method/path/status/latency_ms/
  req_size/res_size を持つ）を受け取り、`Logavo.Logs.ProxyRequest` の
  changeset で検証してから `proxy_requests` テーブルへ一括保存する。
  プロキシレコードは level を持たないため、ログ用（`IngestController`）の
  バリデーションとは分離している。保存後は `Logavo.PubSub` の
  `"proxy_requests"` トピックへ別トピックでブロードキャストする。

  認証は省略（localhost 前提, spec 5）。新規依存は追加しない。
  """
  use LogavoWeb, :controller

  alias Logavo.Repo
  alias Logavo.Logs.ProxyRequest

  # ログとは別のトピック。broadcast メッセージは
  # {:new_proxy_requests, [%ProxyRequest{}, ...]}。
  @topic "proxy_requests"

  def create(conn, %{"entries" => entries}) when is_list(entries) do
    changesets = Enum.map(entries, &build_changeset/1)

    case Enum.filter(changesets, &(not &1.valid?)) do
      [] ->
        inserted = insert_all(changesets)

        if inserted != [] do
          Phoenix.PubSub.broadcast(Logavo.PubSub, @topic, {:new_proxy_requests, inserted})
        end

        conn
        |> put_status(:ok)
        |> json(%{accepted: length(inserted)})

      invalid ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid entries", details: Enum.map(invalid, &translate_errors/1)})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid entries", details: ["expected \"entries\" to be a list"]})
  end

  defp build_changeset(entry) when is_map(entry) do
    ProxyRequest.changeset(%ProxyRequest{}, normalize(entry))
  end

  defp build_changeset(_other), do: ProxyRequest.changeset(%ProxyRequest{}, %{})

  # ASSUMPTION: proxy_requests テーブルは spec 2.2 の meta 内容
  # (method/path/status/latency_ms/req_size/res_size) をフラットなカラムとして
  # 持つ前提で、meta の各キーをトップレベルへ持ち上げてから changeset に渡す。
  # level はプロキシレコードでは扱わないため取り除く。
  defp normalize(%{"meta" => meta} = entry) when is_map(meta) do
    entry
    |> Map.delete("meta")
    |> Map.delete("level")
    |> Map.merge(meta)
  end

  defp normalize(entry), do: Map.delete(entry, "level")

  defp insert_all(changesets) do
    {:ok, inserted} =
      Repo.transaction(fn ->
        Enum.map(changesets, &Repo.insert!/1)
      end)

    inserted
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
