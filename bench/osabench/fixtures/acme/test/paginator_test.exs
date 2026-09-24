defmodule Acme.PaginatorTest do
  use ExUnit.Case, async: true

  alias Acme.Paginator

  test "first page" do
    assert Paginator.page(Enum.to_list(1..10), 1, 3) == [1, 2, 3]
  end

  test "last partial page" do
    assert Paginator.page(Enum.to_list(1..10), 4, 3) == [10]
  end

  test "page_count rounds up" do
    assert Paginator.page_count(Enum.to_list(1..10), 3) == 4
  end
end
