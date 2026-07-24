defmodule LogavoWeb.LogsControllerTest do
  use LogavoWeb.ConnCase, async: true

  alias Logavo.Repo

  # ASSUMPTION: server-schema の `Logavo.Logs` 生成関数名は本タスクからは
  # 確定できないため、テストは log_entries テーブルへ直接行を挿入する
  # （insert_all + 文字列ソースでスキーマの型付けを経由しない）。inserted_at は
  # TEXT 列にそのまま格納され、コントローラは必要列だけを select するので、
  # スキーマの inserted_at の Ecto 型に依存せず検証できる。
  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp insert_entry(attrs) do
    row =
      %{
        timestamp: "2026-07-25T00:00:00.000Z",
        source: "app",
        level: "info",
        message: "hello",
        raw: "raw hello",
        meta: nil,
        inserted_at: "2026-07-25T00:00:00.000Z"
      }
      |> Map.merge(Map.new(attrs))

    {1, _} = Repo.insert_all("log_entries", [row])
    row
  end

  describe "GET /api/logs" do
    test "returns all entries newest-first", %{conn: conn} do
      insert_entry(timestamp: "2026-07-25T00:00:01.000Z", message: "one")
      insert_entry(timestamp: "2026-07-25T00:00:02.000Z", message: "two")

      body = conn |> get("/api/logs") |> json_response(200)

      assert body["count"] == 2
      assert [%{"message" => "two"}, %{"message" => "one"}] = body["entries"]
    end

    test "filters by source (exact match)", %{conn: conn} do
      insert_entry(source: "api", message: "a")
      insert_entry(source: "web", message: "b")

      body = conn |> get("/api/logs?source=api") |> json_response(200)

      assert body["count"] == 1
      assert [%{"source" => "api"}] = body["entries"]
    end

    test "filters by level", %{conn: conn} do
      insert_entry(level: "error", message: "boom")
      insert_entry(level: "info", message: "ok")

      body = conn |> get("/api/logs?level=error") |> json_response(200)

      assert body["count"] == 1
      assert [%{"level" => "error"}] = body["entries"]
    end

    test "filters by keyword across message and raw", %{conn: conn} do
      insert_entry(message: "connection timeout", raw: "x")
      insert_entry(message: "ok", raw: "retry timeout in raw")
      insert_entry(message: "unrelated", raw: "nothing here")

      body = conn |> get("/api/logs?q=timeout") |> json_response(200)

      assert body["count"] == 2
    end

    test "filters by from/to range on timestamp", %{conn: conn} do
      insert_entry(timestamp: "2026-07-01T00:00:00.000Z", message: "old")
      insert_entry(timestamp: "2026-07-15T00:00:00.000Z", message: "mid")
      insert_entry(timestamp: "2026-07-30T00:00:00.000Z", message: "new")

      body =
        conn
        |> get("/api/logs?from=2026-07-10T00:00:00Z&to=2026-07-20T00:00:00Z")
        |> json_response(200)

      assert body["count"] == 1
      assert [%{"message" => "mid"}] = body["entries"]
    end

    test "combines multiple filters", %{conn: conn} do
      insert_entry(source: "api", level: "error", message: "db timeout")
      insert_entry(source: "api", level: "info", message: "db timeout")
      insert_entry(source: "web", level: "error", message: "db timeout")

      body = conn |> get("/api/logs?source=api&level=error&q=timeout") |> json_response(200)

      assert body["count"] == 1
      assert [%{"source" => "api", "level" => "error"}] = body["entries"]
    end

    test "respects limit", %{conn: conn} do
      for i <- 1..5, do: insert_entry(message: "m#{i}")

      body = conn |> get("/api/logs?limit=2") |> json_response(200)

      assert body["count"] == 2
    end

    test "decodes meta json into an object", %{conn: conn} do
      insert_entry(message: "with meta", meta: ~s({"file":"app.log","line_no":10}))

      body = conn |> get("/api/logs?q=meta") |> json_response(200)

      assert [%{"meta" => %{"file" => "app.log", "line_no" => 10}}] = body["entries"]
    end

    test "returns empty result when nothing matches", %{conn: conn} do
      insert_entry(source: "api")

      body = conn |> get("/api/logs?source=does-not-exist") |> json_response(200)

      assert body["count"] == 0
      assert body["entries"] == []
    end
  end
end
