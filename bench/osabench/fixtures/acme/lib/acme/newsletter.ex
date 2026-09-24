defmodule Acme.Newsletter do
  @moduledoc "Newsletter subscriptions."

  def subscribe(list, email) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i, email) do
      {:ok, [email | list]}
    else
      {:error, :invalid_email}
    end
  end
end
