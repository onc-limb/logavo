defmodule LogavoWeb.DashboardLive do
  @moduledoc """
  リアルタイムログダッシュボード（spec Phase 2）。

  マウント時に `Logavo.PubSub` を購読し、`POST /api/ingest` の保存後に
  ブロードキャストされる新着ログをリロードなしで表示する。レベル別に
  色分けし、表示件数には上限（`@max_rows`）を設ける。

  依存最小主義（spec 5.1）に従い、アセットパイプラインは使わず素の CSS を
  `priv/static/assets/` から静的配信する。対象は localhost のみ。
  """
  use LogavoWeb, :live_view

  # server-ingest（保存後に `Logavo.Logs` 経由でブロードキャストする）が発行する
  # トピック。ダッシュボードはこの単一トピックだけを購読し、server-ingest 側の
  # 発行トピックと 1 対 1 で対応させる（推測で複数トピックを購読して取りこぼしを
  # 隠す、という設計は採らない）。この契約は接続済み LiveView テストで
  # subscribe → broadcast → 再描画の実経路として検証する。
  #
  # ASSUMPTION: server-ingest と同一トピック名であることが本ダッシュボードの
  # リアルタイム表示の前提。トピックを変更する場合は server-ingest の
  # ブロードキャストと dashboard_live_test.exs の @topic も併せて更新すること。
  @topic "logs"

  # 表示件数の上限。ローカル開発用途なので DOM を軽く保つ。
  @max_rows 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Logavo.PubSub, @topic)
    end

    socket =
      socket
      |> assign(:max_rows, @max_rows)
      |> assign(:logs, initial_logs(@max_rows))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="dashboard" class="dashboard">
      <%!-- root.html.heex は本タスクのスコープ外のため、ダッシュボード自身が素の
            CSS を静的配信（/assets/dashboard.css）経由で読み込む。LiveView の単一
            ルート要素制約を満たすようコンテナ内に静的に配置する。静的マークアップ
            なので差分更新では再送されず、初回描画時に一度だけ送出される。 --%>
      <link rel="stylesheet" href="/assets/dashboard.css" />

      <h1 class="dashboard-title">logavo dashboard</h1>

      <p :if={@logs == []} id="empty-state" class="dashboard-empty">
        まだログはありません。監視対象にログが書き込まれるとここに流れます。
      </p>

      <ul id="log-list" class="log-list">
        <li
          :for={log <- @logs}
          id={"log-#{log.id}"}
          class={"log-row log-level-#{log.level}"}
          data-level={log.level}
        >
          <span class="log-timestamp"><%= log.timestamp %></span>
          <span class="log-source"><%= log.source %></span>
          <span class="log-level-badge"><%= log.level %></span>
          <span class="log-message"><%= log.message %></span>
        </li>
      </ul>
    </div>
    """
  end

  # --- PubSub 受信 -------------------------------------------------------
  # ASSUMPTION: server-ingest がブロードキャストするメッセージの tag は本タスクの
  # スコープ内から確定できないため、特定 tag の whitelist ではなく「ログ（map /
  # struct、またはそのリスト）を載せた任意のメッセージ」を広く受理する。こうする
  # ことで tag 名が推測と食い違っても（例: `{:log_created, %LogEntry{}}`）新着が
  # 最後の catch-all で無言破棄されることがない。ログを載せない制御メッセージ
  # だけが catch-all で無視される。

  @impl true
  def handle_info({_tag, entries}, socket) when is_list(entries) do
    {:noreply, prepend(socket, entries)}
  end

  def handle_info({_tag, %{} = entry}, socket) do
    {:noreply, prepend(socket, [entry])}
  end

  def handle_info(entries, socket) when is_list(entries) do
    {:noreply, prepend(socket, entries)}
  end

  def handle_info(%_{} = entry, socket) do
    {:noreply, prepend(socket, [entry])}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- 内部ヘルパ --------------------------------------------------------

  defp prepend(socket, entries) do
    incoming = Enum.map(entries, &normalize/1)
    logs = Enum.take(incoming ++ socket.assigns.logs, socket.assigns.max_rows)
    assign(socket, :logs, logs)
  end

  # 起動時に既存ログを最良努力で読み込む。server-search（Phase 3）で確定する
  # クエリ API 名に密結合しないよう、存在する関数だけを動的ディスパッチで呼ぶ。
  # DB 未接続（テストの Ecto サンドボックス等）でも落ちないよう rescue する。
  defp initial_logs(limit) do
    try do
      cond do
        exported?(:list_recent, 1) ->
          apply(Logavo.Logs, :list_recent, [limit])

        exported?(:recent_log_entries, 1) ->
          apply(Logavo.Logs, :recent_log_entries, [limit])

        exported?(:list_log_entries, 1) ->
          apply(Logavo.Logs, :list_log_entries, [limit])

        exported?(:list_log_entries, 0) ->
          Logavo.Logs |> apply(:list_log_entries, []) |> Enum.take(limit)

        true ->
          []
      end
      |> Enum.map(&normalize/1)
    rescue
      _ -> []
    end
  end

  defp exported?(fun, arity) do
    Code.ensure_loaded?(Logavo.Logs) and function_exported?(Logavo.Logs, fun, arity)
  end

  # ログエントリ（%LogEntry{} 構造体・atom キーの map・JSON 由来の文字列キー
  # map のいずれか）を表示用の正規化 map に変換する。spec 2.1 のフィールド。
  defp normalize(entry) do
    %{
      id: field(entry, :id) || System.unique_integer([:positive, :monotonic]),
      timestamp: to_text(field(entry, :timestamp)),
      source: to_text(field(entry, :source)),
      level: normalize_level(field(entry, :level)),
      message: to_text(field(entry, :message)),
      raw: to_text(field(entry, :raw))
    }
  end

  defp field(entry, key) when is_map(entry) do
    case Map.fetch(entry, key) do
      {:ok, value} -> value
      :error -> Map.get(entry, Atom.to_string(key))
    end
  end

  defp field(_entry, _key), do: nil

  # spec 2.1 の level enum に丸める（debug / info / warn / error / unknown）。
  defp normalize_level(level) do
    case level |> to_text() |> String.downcase() do
      value when value in ["debug", "info", "warn", "error"] -> value
      "warning" -> "warn"
      _ -> "unknown"
    end
  end

  defp to_text(nil), do: ""
  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: to_string(value)
end
