defmodule Acme.Http.Headers do
  @moduledoc "HTTP header parsing."

  @doc "Parses `\"Name: value\"` into `{\"name\", \"value\"}`."
  def parse_header(line) do
    [name, value] = String.split(line, ":", parts: 2)
    {name |> String.trim() |> String.downcase(), String.trim(value)}
  end
end
