defmodule LogavoWeb.Router do
  use LogavoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LogavoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LogavoWeb do
    pipe_through :browser

    get "/", PageController, :home
    # リアルタイムログダッシュボード（spec Phase 2, localhost 前提）。
    live "/dashboard", DashboardLive, :index
  end

  # 取り込みAPI（localhost 前提のため認証なし, spec 3.1 / 5）。
  scope "/api", LogavoWeb do
    pipe_through :api

    post "/ingest", IngestController, :create
    post "/proxy", ProxyIngestController, :create
    # 検索API（spec 3.2 / Phase 3, localhost 前提）。
    get "/logs", LogsController, :index
  end
end
