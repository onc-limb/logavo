defmodule LogavoWeb.IngestController do
  @moduledoc """
  ログ取り込みエンドポイント (`POST /api/ingest`)。

  spec 3.1 のバッチ送信を受け取り、各エントリを `Logavo.Logs.LogEntry`
  の changeset で検証（level enum / 必須項目など spec 2.1・2.3）してから
  一括保存する。1 件でも検証に失敗した場合は何も保存せず 422 を返す。
  保存に成功したら `Logavo.PubSub` の `"logs"` トピックへブロードキャストし、
  LiveView ダッシュボードがリロードなしで購読できるようにする。

  認証は Phase 1 では省略（localhost 前提, spec 3.1 / 5）。
  中核依存（Phoenix/Ecto/Jason/PubSub）のみを使用し、新規依存は追加しない。
  """
  use LogavoWeb, :controller

  alias Logavo.Repo
  alias Logavo.Logs.LogEntry

  # ダッシュボードが購読するトピック。broadcast メッセージは
  # {:new_logs, [%LogEntry{}, ...]}。
  @topic "logs"

  def create(conn, %{"entries" => entries}) when is_list(entries) do
    changesets = Enum.map(entries, &build_changeset/1)

    case Enum.filter(changesets, &(not &1.valid?)) do
      [] ->
        inserted = insert_all(changesets)

        if inserted != [] do
          Phoenix.PubSub.broadcast(Logavo.PubSub, @topic, {:new_logs, inserted})
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
    LogEntry.changeset(%LogEntry{}, normalize(entry))
  end

  # entry がそもそもオブジェクトでない場合は空 changeset で必須検証に落とす。
  defp build_changeset(_other), do: LogEntry.changeset(%LogEntry{}, %{})

  # ASSUMPTION: spec 2.3 の通り meta は「JSON 文字列」として保存される
  # (`field :meta, :string`) 前提で、受信した meta オブジェクトを Jason で
  # 文字列化してから changeset に渡す。既に文字列 / nil の場合はそのまま。
  defp normalize(%{"meta" => meta} = entry) when is_map(meta) do
    Map.put(entry, "meta", Jason.encode!(meta))
  end

  defp normalize(entry), do: entry

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
