defmodule Acme.Users do
  @moduledoc "User records."

  def register(name, email) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i, email) do
      Acme.Metrics.emit("users.registered", 1)
      {:ok, %{name: name, email: String.downcase(email)}}
    else
      {:error, :invalid_email}
    end
  end
end
