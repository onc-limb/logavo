defmodule LogavoWeb.DashboardLive do
  @moduledoc """
  リアルタイムログダッシュボード（spec Phase 2）＋フィルタ検索 UI（spec Phase 3）
  ＋プロキシリクエスト可視化（spec Phase 4）。

  マウント時に `Logavo.PubSub` を購読し、`POST /api/ingest` の保存後に
  ブロードキャストされる新着ログをリロードなしで表示する。レベル別に
  色分けし、表示件数には上限（`@max_rows`）を設ける。

  Phase 3 として source / level / keyword / 期間(from,to) のフィルタ UI を追加する。
  絞り込みはクライアント側に届いている表示バッファ（`@logs`）に対してその場で
  適用し、結果を `@visible` に反映する。フィルタ未指定時は全件表示なので、
  リアルタイム表示の既存挙動はそのまま保たれる。サーバ横断の検索は
  `GET /api/logs`（`LogavoWeb.LogsController`）が担う。

  Phase 4 として `proxy_requests` テーブル（server-schema）を用いた 2 つのビューを
  追加する: 『遅い順（latency_ms 降順）』と『ステータス別集計』。データはマウント
  時と、プロキシ計測ログのブロードキャスト受信時、および明示的な再読み込み
  （`refresh_proxy`）で `Logavo.Logs` から読み直す。集計・並び替えは可能な限り
  server-schema のクエリ（全件対象）に委ね、直近ウィンドウのメモリ内計算に
  依存しない。

  依存最小主義（spec 5.1）に従い、アセットパイプラインは使わず素の CSS を
  `priv/static/assets/` から静的配信する。対象は localhost のみ。
  """
  use LogavoWeb, :live_view

  # server-ingest（保存後に `Logavo.Logs` 経由でブロードキャストする）が発行する
  # トピック。ダッシュボードはこの単一トピックだけを購読し、server-ingest 側の
  # 発行トピックと 1 対 1 で対応させる（推測で複数トピックを購読して取りこぼしを
  # 隠す、という設計は採らない）。プロキシ計測ログ（`POST /api/proxy` 保存後の
  # ブロードキャスト）も同じ contract に載せ、受信側は内容（`latency_ms` の有無）で
  # ログ一覧とプロキシビューへ振り分ける（`route_entries` 参照）。この契約は
  # 接続済み LiveView テストで subscribe → broadcast → 再描画の実経路として検証する。
  #
  # ASSUMPTION: server-ingest / プロキシ保存と同一トピック名であることが本
  # ダッシュボードのリアルタイム表示の前提。トピックを変更する場合は server 側の
  # ブロードキャストと dashboard_live_test.exs の @topic も併せて更新すること。
  @topic "logs"

  # 表示件数の上限。ローカル開発用途なので DOM を軽く保つ。
  @max_rows 200

  # 『遅い順』に表示するプロキシリクエストの上限。
  @slow_limit 50

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
      |> load_proxy()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    # Phase 2 のダッシュボードテストは max_rows / logs だけを持つソケットを直接
    # 組み立てて render を呼ぶ（mount を経由しない）。Phase 3/4 で filters / visible /
    # proxy_* を追加したことでこの既存テスト経路が壊れないよう、未設定なら既定へ
    # フォールバックする。実運用では mount が全て設定済みのため assign_new は
    # スキップされる。
    assigns = assign_new(assigns, :filters, fn -> default_filters() end)

    assigns =
      assign_new(assigns, :visible, fn ->
        visible_logs(assigns.logs, assigns.filters)
      end)

    assigns = assign_new(assigns, :proxy_slow, fn -> [] end)
    assigns = assign_new(assigns, :proxy_status, fn -> [] end)

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

      <%!-- プロキシリクエストビュー（spec Phase 4）。proxy_requests テーブルを
            もとに『ステータス別集計』と『遅い順（latency_ms 降順）』を表示する。 --%>
      <section id="proxy-views" class="proxy-views">
        <div class="proxy-header">
          <h2 class="proxy-title">プロキシリクエスト</h2>
          <button type="button" phx-click="refresh_proxy" class="proxy-refresh">再読み込み</button>
        </div>

        <div class="proxy-status">
          <h3 class="proxy-subtitle">ステータス別集計</h3>
          <p :if={@proxy_status == []} id="proxy-status-empty" class="proxy-empty">
            プロキシ経由のリクエストはまだありません。
          </p>
          <table :if={@proxy_status != []} id="proxy-status-table" class="proxy-status-table">
            <thead>
              <tr><th>status</th><th>count</th></tr>
            </thead>
            <tbody>
              <tr
                :for={{status, count} <- @proxy_status}
                id={"proxy-status-#{status}"}
                class={"proxy-status-row proxy-status-#{status_class(status)}"}
                data-status={status}
              >
                <td class="proxy-status-code"><%= status %></td>
                <td class="proxy-status-count"><%= count %></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="proxy-slow">
          <h3 class="proxy-subtitle">遅い順（latency_ms）</h3>
          <p :if={@proxy_slow == []} id="proxy-slow-empty" class="proxy-empty">
            プロキシ経由のリクエストはまだありません。
          </p>
          <table :if={@proxy_slow != []} id="proxy-slow-table" class="proxy-slow-table">
            <thead>
              <tr>
                <th>latency_ms</th>
                <th>method</th>
                <th>path</th>
                <th>status</th>
                <th>req</th>
                <th>res</th>
                <th>time</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={r <- @proxy_slow}
                id={"proxy-req-#{r.id}"}
                class={"proxy-row proxy-status-#{status_class(r.status)}"}
                data-latency={r.latency_ms}
              >
                <td class="proxy-latency"><%= r.latency_ms %></td>
                <td class="proxy-method"><%= r.method %></td>
                <td class="proxy-path"><%= r.path %></td>
                <td class="proxy-status-cell"><%= r.status %></td>
                <td class="proxy-req-size"><%= r.req_size %></td>
                <td class="proxy-res-size"><%= r.res_size %></td>
                <td class="proxy-timestamp"><%= r.timestamp %></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  # --- フィルタ / プロキシイベント ---------------------------------------

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, socket |> assign(:filters, coerce_filters(filters)) |> assign_visible()}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(:filters, default_filters()) |> assign_visible()}
  end

  def handle_event("refresh_proxy", _params, socket) do
    {:noreply, load_proxy(socket)}
  end

  # --- PubSub 受信 -------------------------------------------------------
  # ASSUMPTION: server-ingest / proxy-ingest がブロードキャストするメッセージの
  # tag は本タスクのスコープから確定できないため、特定 tag の whitelist ではなく
  # 「ログ（map / struct、またはそのリスト）を載せた任意のメッセージ」を広く
  # 受理する。受理したエントリは内容で振り分ける（`latency_ms` を持つものは
  # プロキシ計測ログとみなしプロキシビューを読み直し、それ以外はログ一覧へ
  # 先頭追加する）。ログを載せない制御メッセージだけが catch-all で無視される。

  @impl true
  def handle_info({_tag, entries}, socket) when is_list(entries) do
    {:noreply, route_entries(socket, entries)}
  end

  def handle_info({_tag, %{} = entry}, socket) do
    {:noreply, route_entries(socket, [entry])}
  end

  def handle_info(entries, socket) when is_list(entries) do
    {:noreply, route_entries(socket, entries)}
  end

  def handle_info(%_{} = entry, socket) do
    {:noreply, route_entries(socket, [entry])}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- 内部ヘルパ --------------------------------------------------------

  # 受信エントリを内容で振り分ける。プロキシ計測ログ（`latency_ms` を持つ）が
  # 含まれればプロキシビューを読み直し、通常ログはログ一覧へ先頭追加する。
  defp route_entries(socket, entries) do
    {proxy, logs} = Enum.split_with(entries, &proxy_entry?/1)
    socket = if logs == [], do: socket, else: prepend(socket, logs)
    if proxy == [], do: socket, else: load_proxy(socket)
  end

  defp proxy_entry?(entry) when is_map(entry) do
    Map.has_key?(entry, :latency_ms) or Map.has_key?(entry, "latency_ms")
  end

  defp proxy_entry?(_), do: false

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

  # --- プロキシ（Phase 4） -----------------------------------------------

  # プロキシビュー（遅い順 / ステータス別集計）を `proxy_requests` から読み直す。
  # 集計・並び替えは全リクエストが対象になるよう、可能な限り server-schema の
  # クエリ（DB 側で latency ソート / status 集計）に委ねる。
  defp load_proxy(socket) do
    socket
    |> assign(:proxy_slow, fetch_slow_requests(@slow_limit))
    |> assign(:proxy_status, fetch_status_counts())
  end

  # 『遅い順』は server-schema の latency ソート済みクエリ（slowest_proxy_requests/1）を
  # 優先し、DB 側で全リクエストから遅い順に絞る。無い場合のみ、直近スライスを
  # メモリ内で latency 降順ソートするフォールバックへ落ちる（この経路では
  # 直近ウィンドウの制限が残ることを許容する）。DB 未接続でも落ちないよう rescue。
  defp fetch_slow_requests(limit) do
    try do
      if exported?(:slowest_proxy_requests, 1) do
        Logavo.Logs
        |> apply(:slowest_proxy_requests, [limit])
        |> Enum.map(&normalize_proxy/1)
      else
        @max_rows |> fetch_proxy_requests() |> slow_sort()
      end
    rescue
      _ -> []
    end
  end

  # 『ステータス別集計』は全リクエストが対象。server-schema の集計クエリ
  # （proxy_status_counts/0）を優先し、DB 側で全件を status ごとに集計する。無い
  # 場合のみ、直近スライスからのメモリ内集計へフォールバックする（この経路は
  # 直近ウィンドウに限られる）。DB 未接続でも落ちないよう rescue。
  defp fetch_status_counts do
    try do
      if exported?(:proxy_status_counts, 0) do
        Logavo.Logs
        |> apply(:proxy_status_counts, [])
        |> normalize_status_counts()
      else
        @max_rows |> fetch_proxy_requests() |> status_counts()
      end
    rescue
      _ -> []
    end
  end

  # `Logavo.Logs` から proxy_requests を最良努力で読み込む（フォールバック用の
  # 直近スライス取得）。server-schema 側で確定するクエリ関数名に密結合しないよう、
  # 存在する関数だけを動的ディスパッチする。latency ソート済みクエリ
  # （slowest_proxy_requests）は `fetch_slow_requests` が直接優先するため、ここでは
  # 扱わない。DB 未接続でも落ちないよう rescue する。
  defp fetch_proxy_requests(limit) do
    try do
      cond do
        exported?(:list_proxy_requests, 1) ->
          apply(Logavo.Logs, :list_proxy_requests, [limit])

        exported?(:recent_proxy_requests, 1) ->
          apply(Logavo.Logs, :recent_proxy_requests, [limit])

        exported?(:list_recent_proxy_requests, 1) ->
          apply(Logavo.Logs, :list_recent_proxy_requests, [limit])

        exported?(:list_proxy_requests, 0) ->
          Logavo.Logs |> apply(:list_proxy_requests, []) |> Enum.take(limit)

        true ->
          []
      end
      |> Enum.map(&normalize_proxy/1)
    rescue
      _ -> []
    end
  end

  # latency_ms 降順で並べ、上限件数だけ返す（メモリ内ソートのフォールバック）。
  defp slow_sort(requests) do
    requests
    |> Enum.sort_by(& &1.latency_ms, :desc)
    |> Enum.take(@slow_limit)
  end

  # status ごとの件数を集計し、status 昇順で返す（メモリ内集計のフォールバック）。
  defp status_counts(requests) do
    requests
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, list} -> {status, length(list)} end)
    |> Enum.sort_by(fn {status, _} -> status end)
  end

  # server-schema の集計クエリ（proxy_status_counts/0）の戻り値を表示用の
  # {status, count} 昇順リストに正規化する。{status, count} タプルのリスト、または
  # `%{status: _, count: _}` map のリストのいずれにも対応する。
  defp normalize_status_counts(rows) do
    rows
    |> Enum.map(fn
      {status, count} -> {to_int(status), to_int(count)}
      %{} = row -> {to_int(field(row, :status)), to_int(field(row, :count))}
    end)
    |> Enum.sort_by(fn {status, _} -> status end)
  end

  # proxy_requests の 1 行（%ProxyRequest{} 構造体 / atom キー map / 文字列キー
  # map）を表示用の正規化 map に変換する。spec 2.2 のフィールド。
  defp normalize_proxy(entry) do
    %{
      id: field(entry, :id) || System.unique_integer([:positive, :monotonic]),
      timestamp: to_text(field(entry, :timestamp)),
      method: to_text(field(entry, :method)),
      path: to_text(field(entry, :path)),
      status: to_int(field(entry, :status)),
      latency_ms: to_int(field(entry, :latency_ms)),
      req_size: to_int(field(entry, :req_size)),
      res_size: to_int(field(entry, :res_size))
    }
  end

  # status からステータスクラス（色分け用）を決める。
  defp status_class(status) when is_integer(status) do
    cond do
      status >= 500 -> "5xx"
      status >= 400 -> "4xx"
      status >= 300 -> "3xx"
      status >= 200 -> "2xx"
      true -> "other"
    end
  end

  defp status_class(_), do: "other"

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  # --- 共通ヘルパ --------------------------------------------------------

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
