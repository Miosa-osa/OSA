defmodule Acme.Util.Strings do
  @moduledoc "Small string helpers."

  def titlecase(text) do
    text
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def truncate(text, max) when byte_size(text) <= max, do: text
  def truncate(text, max), do: String.slice(text, 0, max - 3) <> "..."
end
