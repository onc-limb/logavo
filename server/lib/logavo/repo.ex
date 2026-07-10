defmodule Logavo.Repo do
  use Ecto.Repo,
    otp_app: :logavo,
    adapter: Ecto.Adapters.SQLite3
end
