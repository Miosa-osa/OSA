defmodule Acme.Legacy do
  @moduledoc "Invoice number formats."

  def new_format(id), do: "INV-" <> String.pad_leading(Integer.to_string(id), 6, "0")

  def old_format(id), do: "#" <> Integer.to_string(id)
end
