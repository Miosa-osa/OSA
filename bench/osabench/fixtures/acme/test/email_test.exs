defmodule Acme.EmailTest do
  use ExUnit.Case, async: true

  test "every entry point accepts a good address and rejects a bad one" do
    assert {:ok, _} = Acme.Users.register("ada", "ada@example.com")
    assert {:error, :invalid_email} = Acme.Users.register("ada", "not-an-email")
    assert {:ok, _} = Acme.Accounts.change_billing_email(%{}, "billing@example.com")
    assert {:error, :invalid_email} = Acme.Accounts.change_billing_email(%{}, "x@y")
    assert {:ok, ["n@example.org"]} = Acme.Newsletter.subscribe([], "n@example.org")
    assert {:error, :invalid_email} = Acme.Newsletter.subscribe([], "@example.org")
  end
end
