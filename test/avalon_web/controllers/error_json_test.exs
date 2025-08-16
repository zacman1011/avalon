defmodule AvalonWeb.ErrorJSONTest do
  use AvalonWeb.ConnCase, async: true

  test "renders 404" do
    assert AvalonWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert AvalonWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
