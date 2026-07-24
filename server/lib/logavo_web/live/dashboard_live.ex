defmodule LogavoWeb.DashboardLive do
  @moduledoc """
  リアルタイムログダッシュボード（spec Phase 2）＋フィルタ検索 UI（spec Phase 3）。

  マウント時に `Logavo.PubSub` を購読し、`POST /api/ingest` の保存後に
  ブロードキャストされる新着ログをリロードなしで表示する。レベル別に
  色分けし、表示件数には上限（`@max_rows`）を設ける。

  Phase 3 として source / level / keyword / 期間(from,to) のフィルタ UI を追加する。
  絞り込みはクライアント側に届いている表示バッファ（`@logs`）に対してその場で
  適用し、結果を `@visible` に反映する。フィルタ未指定時は全件表示なので、
  リアルタイム表示の既存挙動はそのまま保たれる。サーバ横断の検索は
  `GET /api/logs`（`LogavoWeb.LogsController`）が担う。

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
      |> assign(:filters, default_filters())
      |> assign(:logs, initial_logs(@max_rows))
      |> assign_visible()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    # Phase 2 のダッシュボードテストは max_rows / logs だけを持つソケットを直接
    # 組み立てて render を呼ぶ（mount を経由しない）。Phase 3 で filters / visible を
    # 追加したことでこの既存テスト経路が壊れないよう、未設定なら既定へフォールバック
    # する。実運用では mount が両者を設定済みのため assign_new はスキップされる。
    assigns = assign_new(assigns, :filters, fn -> default_filters() end)

    assigns =
      assign_new(assigns, :visible, fn ->
        visible_logs(assigns.logs, assigns.filters)
      end)

    ~H"""
    <div id="dashboard" class="dashboard">
      <%!-- root.html.heex は本タスクのスコープ外のため、ダッシュボード自身が素の
            CSS を静的配信（/assets/dashboard.css）経由で読み込む。LiveView の単一
            ルート要素制約を満たすようコンテナ内に静的に配置する。静的マークアップ
            なので差分更新では再送されず、初回描画時に一度だけ送出される。 --%>
      <link rel="stylesheet" href="/assets/dashboard.css" />

      <h1 class="dashboard-title">logavo dashboard</h1>

      <%!-- フィルタ UI（spec Phase 3）。phx-change で入力のたびに絞り込む。
            未指定の項目は無視されるため、既定では全件が表示される。 --%>
      <form id="log-filters" class="dashboard-filters" phx-change="filter" phx-submit="filter">
        <input
          type="text"
          name="filters[source]"
          value={@filters.source}
          placeholder="source"
          class="filter-source"
        />
        <select name="filters[level]" class="filter-level">
          <option value="" selected={@filters.level == ""}>level: すべて</option>
          <option
            :for={level <- ~w(debug info warn error unknown)}
            value={level}
            selected={@filters.level == level}
          >
            <%= level %>
          </option>
        </select>
        <input
          type="text"
          name="filters[keyword]"
          value={@filters.keyword}
          placeholder="keyword"
          class="filter-keyword"
        />
        <input type="datetime-local" name="filters[from]" value={@filters.from} class="filter-from" />
        <input type="datetime-local" name="filters[to]" value={@filters.to} class="filter-to" />
        <button type="button" phx-click="reset" class="filter-reset">クリア</button>
      </form>

      <p :if={@visible == []} id="empty-state" class="dashboard-empty">
        まだログはありません。監視対象にログが書き込まれるとここに流れます。
      </p>

      <ul id="log-list" class="log-list">
        <li
          :for={log <- @visible}
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

  # --- フィルタイベント --------------------------------------------------

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, socket |> assign(:filters, coerce_filters(filters)) |> assign_visible()}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(:filters, default_filters()) |> assign_visible()}
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
    socket |> assign(:logs, logs) |> assign_visible()
  end

  # 現在のフィルタを表示バッファに適用し `@visible` を更新する。
  # Phase 2 のテストは filters を持たないソケットを直接組み立てて handle_info を
  # 通すことがあるため、未設定なら既定フィルタ（全件通過）にフォールバックする。
  defp assign_visible(socket) do
    filters = Map.get(socket.assigns, :filters) || default_filters()
    assign(socket, :visible, visible_logs(socket.assigns.logs, filters))
  end

  defp default_filters do
    %{source: "", level: "", keyword: "", from: "", to: ""}
  end

  defp coerce_filters(params) do
    %{
      source: trimmed(params, "source"),
      level: trimmed(params, "level"),
      keyword: trimmed(params, "keyword"),
      from: trimmed(params, "from"),
      to: trimmed(params, "to")
    }
  end

  defp trimmed(params, key), do: params |> Map.get(key, "") |> to_string() |> String.trim()

  # 表示バッファをフィルタで絞り込む。空のフィルタ項目は無視する（＝全件通過）。
  defp visible_logs(logs, filters) do
    Enum.filter(logs, &matches?(&1, filters))
  end

  defp matches?(log, filters) do
    contains?(log.source, filters.source) and
      level_matches?(log.level, filters.level) and
      keyword_matches?(log, filters.keyword) and
      from_matches?(log.timestamp, filters.from) and
      to_matches?(log.timestamp, filters.to)
  end

  defp contains?(_value, ""), do: true

  defp contains?(value, needle) do
    String.contains?(String.downcase(value), String.downcase(needle))
  end

  defp level_matches?(_level, ""), do: true
  defp level_matches?(level, want), do: level == want

  defp keyword_matches?(_log, ""), do: true

  defp keyword_matches?(log, keyword) do
    needle = String.downcase(keyword)
    String.contains?(String.downcase(log.message), needle) or
      String.contains?(String.downcase(log.raw), needle)
  end

  # 期間は timestamp の辞書順比較で判定する。datetime-local(例 "2026-07-25T12:34")
  # は timestamp(ISO8601)の接頭辞に相当する。ただし素朴に比較すると、保存値の
  # ミリ秒付きフォーマット（"...12:34:56.000Z"）と分単位の境界指定（"...12:34"）が
  # 食い違い、境界の秒付きログを取りこぼす（to に分を指定するとその分内の秒付き
  # ログが除外される等）。そこで境界値を精度単位の端に正規化してから比較する:
  #   * from は下端 = 末尾 "Z" を落とした接頭辞（その精度の先頭を含む）
  #   * to   は上端 = 末尾 "Z" を落として高位センチネル "~" を付す（その精度の末尾まで含む）
  # "~"(0x7E) は timestamp が取りうる文字（数字 / '.' / ':' / 'T' / 'Z'(0x5A)）より
  # 大きいため、当該精度単位に属する全ログが上端以下に収まり、次の単位は除外される。
  defp from_matches?(_ts, ""), do: true
  defp from_matches?(ts, from), do: ts >= lower_bound(from)

  defp to_matches?(_ts, ""), do: true
  defp to_matches?(ts, to), do: ts <= upper_bound(to)

  defp lower_bound(value), do: String.trim_trailing(value, "Z")
  defp upper_bound(value), do: String.trim_trailing(value, "Z") <> "~"

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
