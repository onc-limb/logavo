defmodule LogavoWeb.IngestControllerTest do
  use LogavoWeb.ConnCase

  alias Logavo.Repo
  alias Logavo.Logs.LogEntry
  alias Logavo.Logs.ProxyRequest

  # spec 2.1 のログエントリ
  @log_entry %{
    "timestamp" => "2026-07-09T12:34:56.789Z",
    "source" => "backend-api",
    "level" => "error",
    "message" => "connection refused",
    "raw" => "2026-07-09 12:34:56 [ERROR] connection refused",
    "meta" => %{"file" => "/var/log/app.log", "line_no" => 1024}
  }

  # spec 2.2 の HTTP リクエストログ
  @proxy_entry %{
    "timestamp" => "2026-07-09T12:34:56.789Z",
    "source" => "proxy",
    "level" => "info",
    "message" => "GET /api/users 200",
    "meta" => %{
      "method" => "GET",
      "path" => "/api/users",
      "status" => 200,
      "latency_ms" => 42,
      "req_size" => 0,
      "res_size" => 1532
    }
  }

  defp post_json(conn, path, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, Jason.encode!(payload))
  end

  describe "POST /api/ingest（ログ取り込み）" do
    test "バッチを保存し accepted 件数を 200 で返す", %{conn: conn} do
      conn = post_json(conn, "/api/ingest", %{entries: [@log_entry, @log_entry]})

      assert json_response(conn, 200) == %{"accepted" => 2}
      assert Repo.aggregate(LogEntry, :count) == 2
    end

    test "保存後に PubSub でブロードキャストする", %{conn: conn} do
      :ok = Phoenix.PubSub.subscribe(Logavo.PubSub, "logs")

      post_json(conn, "/api/ingest", %{entries: [@log_entry]})

      assert_receive {:new_logs, [%LogEntry{} = entry]}
      assert entry.source == "backend-api"
    end

    test "検証に失敗するエントリがあれば 422 を返し何も保存しない", %{conn: conn} do
      # 必須項目（timestamp/level/message/raw）を欠くため changeset が invalid。
      conn = post_json(conn, "/api/ingest", %{entries: [%{"source" => "x"}]})

      body = json_response(conn, 422)
      assert body["error"] == "invalid entries"
      assert Repo.aggregate(LogEntry, :count) == 0
    end

    test "entries が無ければ 422 を返す", %{conn: conn} do
      conn = post_json(conn, "/api/ingest", %{"not_entries" => []})
      assert json_response(conn, 422)["error"] == "invalid entries"
    end

    test "entries が配列でなければ 422 を返す", %{conn: conn} do
      conn = post_json(conn, "/api/ingest", %{entries: "oops"})
      assert json_response(conn, 422)["error"] == "invalid entries"
    end
  end

  describe "POST /api/proxy（プロキシメトリクス取り込み）" do
    test "プロキシレコードを保存し accepted 件数を 200 で返す", %{conn: conn} do
      conn = post_json(conn, "/api/proxy", %{entries: [@proxy_entry]})

      assert json_response(conn, 200) == %{"accepted" => 1}
      assert Repo.aggregate(ProxyRequest, :count) == 1
    end

    test "保存後に別トピックで PubSub ブロードキャストする", %{conn: conn} do
      :ok = Phoenix.PubSub.subscribe(Logavo.PubSub, "proxy_requests")

      post_json(conn, "/api/proxy", %{entries: [@proxy_entry]})

      assert_receive {:new_proxy_requests, [%ProxyRequest{} = req]}
      assert req.id
    end

    test "検証に失敗するプロキシエントリがあれば 422 を返し何も保存しない", %{conn: conn} do
      # meta の必須フィールド（path/status/latency_ms/req_size/res_size）を欠くため
      # ProxyRequest.changeset が invalid になり、log 用とは分離した検証経路が走る。
      invalid_proxy_entry = %{
        "timestamp" => "2026-07-09T12:34:56.789Z",
        "source" => "proxy",
        "message" => "broken proxy record",
        "meta" => %{"method" => "GET"}
      }

      conn = post_json(conn, "/api/proxy", %{entries: [invalid_proxy_entry]})

      body = json_response(conn, 422)
      assert body["error"] == "invalid entries"
      assert Repo.aggregate(ProxyRequest, :count) == 0
    end

    test "entries が無ければ 422 を返す", %{conn: conn} do
      conn = post_json(conn, "/api/proxy", %{"nope" => true})
      assert json_response(conn, 422)["error"] == "invalid entries"
    end

    test "entries が配列でなければ 422 を返す", %{conn: conn} do
      conn = post_json(conn, "/api/proxy", %{entries: "oops"})
      assert json_response(conn, 422)["error"] == "invalid entries"
    end
  end
end
