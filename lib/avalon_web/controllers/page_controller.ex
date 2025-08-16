defmodule AvalonWeb.PageController do
  use AvalonWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
