defmodule Canopy.Schemas.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :name, :string
    field :email, :string
    field :password_hash, :string
    field :role, :string, default: "member"
    field :provider, :string, default: "local"
    field :last_login, :utc_datetime

    field :password, :string, virtual: true

    has_many :workspaces, Canopy.Schemas.Workspace, foreign_key: :owner_id

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email, :password, :role, :provider])
    |> validate_required([:name, :email])
    |> validate_format(:email, ~r/@/)
    |> validate_inclusion(:role, ~w(admin member viewer))
    |> unique_constraint(:email)
    |> hash_password()
  end

  defp hash_password(%{valid?: true, changes: %{password: password}} = changeset) do
    put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
  end
  defp hash_password(changeset), do: changeset
end
