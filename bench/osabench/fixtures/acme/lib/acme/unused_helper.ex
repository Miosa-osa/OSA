defmodule Acme.UnusedHelper do
  @moduledoc "Left over from the 1.x importer."

  def normalize_row(row), do: Enum.map(row, &String.trim/1)
end
