defmodule LogavoWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use LogavoWeb, :html

  embed_templates "page_html/*"
end
