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
  end

  # Other scopes may use custom stacks.
  # The ingest API (POST /api/ingest) will be added here in Phase 2.
  # scope "/api", LogavoWeb do
  #   pipe_through :api
  # end
end
