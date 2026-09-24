defmodule Acme.Accounts do
  @moduledoc "Billing accounts."

  def change_billing_email(account, email) do
    if Regex.match?(~r/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i, email) do
      {:ok, Map.put(account, :billing_email, email)}
    else
      {:error, :invalid_email}
    end
  end
end
