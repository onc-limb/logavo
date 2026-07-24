defmodule LogavoWeb.DashboardLiveTest do
  # spec Phase 2 の核（マウント購読・実ブロードキャスト受信・レベル別色分け・
  # 正規化・件数上限）を検証する。
  #
  # 本来は接続済み LiveView（`live/2`）で検証したいが、この環境の
  # phoenix_live_view 1.2.6 は接続テストの DOM 解析に `lazy_html` を要求し、それが
  # 依存に無い（`{:lazy_html, ">= 0.1.0", only: :test}` を足すべき mix.exs は本タスクの
  # 編集対象外で、ここから追加できない）。そこで `live/2` は使わず、実装
  # （DashboardLive）のコールバックと実 PubSub 経路を直接駆動して、同等のふるまいを
  # DOM 解析（＝lazy_html）なしで検証する:
  #
  #   1. subscribe: `transport_pid` を持つ（＝ `connected?` が true）ソケットで
  #      `mount/3` を呼ぶと、実装は @topic を購読する。購読するのはテストプロセス
  #      自身なので、@topic への実ブロードキャストがテストプロセスへ届くことで
  #      「マウント時に @topic を購読する」契約とトピック一致を検証する。トピックが
  #      ずれればメッセージは届かず `assert_receive` が赤になる。
  #   2. broadcast → 再描画: 受信メッセージを `handle_info/2` に渡し、得たソケットの
  #      assigns を実装の `render/1` に通して HTML 文字列化し（`Phoenix.HTML.Safe`。
  #      lazy_html を要する DOM ヘルパは使わない）、レベル別クラスと本文を検証する。
  use LogavoWeb.ConnCase

  alias LogavoWeb.DashboardLive

  # 実装（DashboardLive）と同じ購読トピック。server-ingest の発行トピックに一致。
  @topic "logs"

  # 実装（DashboardLive）と同じ表示件数上限。
  @max_rows 200

  defp entry(attrs) do
    Map.merge(
      %{
        "timestamp" => "2026-07-25T12:34:56.789Z",
        "source" => "backend-api",
        "level" => "info",
        "message" => "hello",
        "raw" => "2026-07-25 12:34:56 [INFO] hello"
      },
      attrs
    )
  end

  # server-ingest の保存後発行を再現し、@topic へ実ブロードキャストする。
  defp broadcast(entry) do
    Phoenix.PubSub.broadcast(Logavo.PubSub, @topic, {:new_log, entry})
  end

  # transport_pid を持たせて `connected?` を true にしたソケットで mount する。
  # これにより実装は @topic をテストプロセスに購読させる。
  defp mount_connected do
    socket = %Phoenix.LiveView.Socket{transport_pid: self(), assigns: %{__changed__: %{}}}
    {:ok, socket} = DashboardLive.mount(%{}, %{}, socket)
    socket
  end

  # 実装の handle_info を実 PubSub メッセージ形（{:new_log, entry}）で駆動する。
  defp feed(socket, entry) do
    {:noreply, socket} = DashboardLive.handle_info({:new_log, entry}, socket)
    socket
  end

  # 現在の assigns を実装の render/1 に通して HTML 文字列を得る。lazy_html を要する
  # DOM ヘルパは使わず、Rendered を素直に iodata 化して文字列にする。__changed__ を
  # nil にして常に全体描画させる。
  defp html_of(socket) do
    %{logs: socket.assigns.logs, max_rows: socket.assigns.max_rows, __changed__: nil}
    |> DashboardLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "マウント時に骨組みと空状態を接続描画する", %{conn: conn} do
    # dead render（GET）はルーティングと初期描画を通しつつ DOM 解析を伴わないため
    # lazy_html 不要。空状態（まだ新着なし）が出ることを確認する。
    html = conn |> get("/dashboard") |> html_response(200)

    assert html =~ "logavo dashboard"
    assert html =~ ~s(id="dashboard")
    assert html =~ ~s(id="log-list")
    assert html =~ ~s(id="empty-state")
  end

  test "実ブロードキャストが購読済みビューにリロードなしで届き、色分けされる" do
    socket = mount_connected()

    # マウント直後は error 行が無い。
    refute html_of(socket) =~ "log-level-error"

    # 購読中トピックへ実ブロードキャスト（server-ingest の保存後発行を再現）。
    broadcast(entry(%{"level" => "error", "message" => "connection refused"}))

    # 購読が成立していれば @topic のメッセージがテストプロセス（＝mount で購読した
    # プロセス）に届く。トピックがずれれば届かず赤になる（＝購読挙動そのものの検証）。
    assert_receive {:new_log, received}

    # 受信メッセージを本来の handle_info 経路へ流し、再描画で error 行が色分けされる。
    socket = feed(socket, received)
    html = html_of(socket)

    assert html =~ ~s(log-level-error")
    assert html =~ "connection refused"
    # ログが流れたので空状態は消える。
    refute html =~ ~s(id="empty-state")
  end

  test "各レベルが固有のクラスを持つ" do
    Enum.reduce(~w(debug info warn error unknown), mount_connected(), fn level, socket ->
      socket = feed(socket, entry(%{"level" => level, "message" => "msg-#{level}"}))
      html = html_of(socket)

      assert html =~ ~s(log-level-#{level}")
      assert html =~ "msg-#{level}"
      socket
    end)
  end

  test "unknown / warning などのレベル表記を正規化する" do
    socket = mount_connected()

    socket = feed(socket, entry(%{"level" => "WARNING", "message" => "as warn"}))
    socket = feed(socket, entry(%{"level" => "weird", "message" => "as unknown"}))

    html = html_of(socket)

    # WARNING → warn、weird → unknown に丸められる。誤って両方 unknown 等に
    # 潰れれば warn クラスが現れず赤になる。
    assert html =~ ~s(log-level-warn")
    assert html =~ "as warn"
    assert html =~ ~s(log-level-unknown")
    assert html =~ "as unknown"
  end

  test "表示件数に上限を設ける" do
    socket =
      Enum.reduce(1..250, mount_connected(), fn n, socket ->
        feed(socket, entry(%{"level" => "info", "message" => "m#{n}", "raw" => "r#{n}"}))
      end)

    html = html_of(socket)

    # 上限は 200。新着はリストの先頭に積まれるため最新 200 件（m250..m51）が残り、
    # 古い 50 件（m50..m1）は間引かれる。単語境界付き正規表現で境界を検証する
    # （m50 は m250/m150 等の部分文字列にはならない）。
    assert html =~ ~r/\bm250\b/
    assert html =~ ~r/\bm51\b/
    refute html =~ ~r/\bm50\b/
    refute html =~ ~r/\bm1\b/

    # 描画される行数がちょうど上限であることも直接検証する。各 <li> の class は
    # `log-row log-level-<level>` で終わるため、その閉じ引用まで含めて数える。
    row_count = length(Regex.scan(~r/log-level-(?:debug|info|warn|error|unknown)"/, html))
    assert row_count == @max_rows
  end
end
