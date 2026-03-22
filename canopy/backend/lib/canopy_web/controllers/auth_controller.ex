defmodule CanopyWeb.AuthController do
  use CanopyWeb, :controller

  alias Canopy.Repo
  alias Canopy.Schemas.User
  import Ecto.Query

  def login(conn, %{"email" => email, "password" => password}) do
    with %User{} = user <- Repo.one(from u in User, where: u.email == ^email),
         true <- Bcrypt.verify_pass(password, user.password_hash) do
      {:ok, token, _claims} =
        Canopy.Guardian.encode_and_sign(user, %{"role" => user.role}, ttl: {1, :hour})

      Repo.update!(Ecto.Changeset.change(user, last_login: DateTime.utc_now() |> DateTime.truncate(:second)))

      json(conn, %{
        token: token,
        user: %{
          id: user.id,
          name: user.name,
          email: user.email,
          role: user.role
        }
      })
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid_credentials"})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "invalid_request", details: "Missing email or password"})
  end

  def refresh(conn, _params) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, _old_claims} <- Canopy.Guardian.decode_and_verify(token),
         {:ok, _old_token, {new_token, new_claims}} <- Canopy.Guardian.refresh(token) do
      json(conn, %{token: new_token, expires_at: new_claims["exp"]})
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid_token"})
    end
  end
end
