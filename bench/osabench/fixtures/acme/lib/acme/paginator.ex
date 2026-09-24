defmodule Acme.Paginator do
  @moduledoc "1-based pagination over a list."

  def page(list, page_number, per_page) when page_number >= 1 and per_page >= 1 do
    Acme.Metrics.emit("paginator.page", page_number)
    Enum.slice(list, (page_number - 1) * per_page, per_page)
  end

  def page_count(list, per_page), do: div(length(list) + per_page - 1, per_page)
end
