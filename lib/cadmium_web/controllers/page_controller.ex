defmodule CadmiumWeb.PageController do
  use CadmiumWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
