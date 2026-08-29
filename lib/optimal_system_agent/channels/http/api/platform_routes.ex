defmodule OptimalSystemAgent.Channels.HTTP.API.PlatformRoutes do
  @moduledoc """
  Platform CRUD routes under /platform prefix.
  Handles tenants, OS instances, and cross-OS grants.
  """
  use Plug.Router
  import OptimalSystemAgent.Channels.HTTP.API.Shared

  alias OptimalSystemAgent.Platform.Tenants
  alias OptimalSystemAgent.Platform.OsInstances
  alias OptimalSystemAgent.Platform.Grants

  @compile {:no_warn_undefined,
            [
              OptimalSystemAgent.Platform.Tenants,
              OptimalSystemAgent.Platform.OsInstances,
              OptimalSystemAgent.Platform.Grants
            ]}

  plug(:match)
  plug(:dispatch)

  # ── Platform-enabled guard ───────────────────────────────────────────

  defp platform_enabled?, do: Application.get_env(:optimal_system_agent, :platform_enabled, false)

  defp platform_unavailable(conn) do
    json(conn, 503, %{error: "platform_unavailable", details: "Platform database not configured"})
  end

  # ── Tenant invite accept (before /:id to avoid match conflict) ─────

  post "/tenants/invite/accept" do
    with_auth(conn, fn _user_id ->
      case conn.body_params do
        %{"token" => token} when is_binary(token) ->
          case Tenants.accept_invite(token) do
            {:ok, _} -> json(conn, 200, %{status: "accepted"})
            {:error, reason} -> json(conn, 422, %{error: to_string(reason)})
          end

        _ ->
          json(conn, 400, %{error: "missing token"})
      end
    end)
  end

  # ── Tenants ─────────────────────────────────────────────────────────

  get "/tenants" do
    with_auth(conn, fn user_id ->
      {page, per_page} = pagination_params(conn)
      tenants = Tenants.list_for_user(user_id)
      total = length(tenants)

      paginated =
        tenants
        |> Enum.drop((page - 1) * per_page)
        |> Enum.take(per_page)

      json(conn, 200, %{tenants: paginated, count: total, page: page, per_page: per_page})
    end)
  end

  post "/tenants" do
    with_auth(conn, fn user_id ->
      try do
        case Tenants.create(user_id, conn.body_params) do
          {:ok, tenant} ->
            json(conn, 201, tenant)

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "validation_failed", details: changeset_errors(cs)})

          {:error, _} ->
            json(conn, 422, %{error: "validation_failed"})
        end
      rescue
        e in Ecto.ConstraintError ->
          json(conn, 422, %{error: "validation_failed", details: constraint_error_details(e)})
      end
    end)
  end

  get "/tenants/:id" do
    with_auth(conn, fn user_id ->
      case authorize_tenant_member(id, user_id, conn) do
        {:ok, _} ->
          case Tenants.get(id) do
            nil -> json(conn, 404, %{error: "not_found"})
            tenant -> json(conn, 200, tenant)
          end

        :error ->
          :ok
      end
    end)
  end

  put "/tenants/:id" do
    with_auth(conn, fn user_id ->
      case authorize_tenant_owner(id, user_id, conn) do
        {:ok, _} ->
          case Tenants.update(id, conn.body_params) do
            {:ok, tenant} ->
              json(conn, 200, tenant)

            {:error, :not_found} ->
              json(conn, 404, %{error: "not_found"})

            {:error, %Ecto.Changeset{} = cs} ->
              json(conn, 422, %{error: "validation_failed", details: changeset_errors(cs)})

            {:error, _} ->
              json(conn, 422, %{error: "validation_failed"})
          end

        :error ->
          :ok
      end
    end)
  end

  delete "/tenants/:id" do
    with_auth(conn, fn user_id ->
      case authorize_tenant_owner(id, user_id, conn) do
        {:ok, _} ->
          case Tenants.delete(id) do
            {:ok, _} -> json(conn, 200, %{status: "deleted"})
            {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
            {:error, _} -> json(conn, 500, %{error: "internal_error"})
          end

        :error ->
          :ok
      end
    end)
  end

  # ── Tenant members ──────────────────────────────────────────────────

  get "/tenants/:id/members" do
    with_auth(conn, fn user_id ->
      case authorize_tenant_member(id, user_id, conn) do
        {:ok, _} ->
          members = Tenants.list_members(id)
          json(conn, 200, %{members: members, count: length(members)})

        :error ->
          :ok
      end
    end)
  end

  post "/tenants/:id/invite" do
    with_auth(conn, fn user_id ->
      case authorize_tenant_owner(id, user_id, conn) do
        {:ok, _} ->
          email = conn.body_params["email"]
          role = conn.body_params["role"] || "member"

          unless is_binary(email) and Regex.match?(~r/^[^\s@]+@[^\s@]+$/, email) do
            json(conn, 422, %{
              error: "validation_failed",
              details: %{email: ["is not a valid email address"]}
            })
          else
            case Tenants.invite_member(id, email, role) do
              {:ok, invite} ->
                json(conn, 201, invite)

              {:error, %Ecto.Changeset{} = cs} ->
                json(conn, 422, %{error: "validation_failed", details: changeset_errors(cs)})

              {:error, _} ->
                json(conn, 422, %{error: "validation_failed"})
            end
          end

        :error ->
          :ok
      end
    end)
  end

  delete "/tenants/:id/members/:member_id" do
    with_auth(conn, fn user_id ->
      case authorize_tenant_owner(id, user_id, conn) do
        {:ok, _} ->
          case Tenants.remove_member(id, member_id) do
            :ok -> json(conn, 200, %{status: "removed"})
            {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
          end

        :error ->
          :ok
      end
    end)
  end

  # ── OS Instances ────────────────────────────────────────────────────

  get "/os" do
    with_auth(conn, fn _user_id ->
      tenant_id = conn.query_params["tenant_id"]

      if is_binary(tenant_id) do
        {page, per_page} = pagination_params(conn)
        instances = OsInstances.list(tenant_id)
        total = length(instances)

        paginated =
          instances
          |> Enum.drop((page - 1) * per_page)
          |> Enum.take(per_page)

        json(conn, 200, %{instances: paginated, count: total, page: page, per_page: per_page})
      else
        json(conn, 400, %{error: "tenant_id query param required"})
      end
    end)
  end

  post "/os" do
    with_auth(conn, fn user_id ->
      tenant_id = conn.body_params["tenant_id"]
      attrs = conn.body_params

      unless is_binary(tenant_id) do
        json(conn, 422, %{error: "validation_failed", details: %{tenant_id: ["is required"]}})
      else
        case OsInstances.create(tenant_id, user_id, attrs) do
          {:ok, instance} ->
            json(conn, 201, instance)

          {:error, %Ecto.Changeset{} = cs} ->
            json(conn, 422, %{error: "validation_failed", details: changeset_errors(cs)})

          {:error, _} ->
            json(conn, 422, %{error: "validation_failed"})
        end
      end
    end)
  end

  get "/os/:id" do
    with_auth(conn, fn _user_id ->
      case OsInstances.get(id) do
        nil -> json(conn, 404, %{error: "not_found"})
        instance -> json(conn, 200, instance)
      end
    end)
  end

  put "/os/:id" do
    with_auth(conn, fn _user_id ->
      case OsInstances.update(id, conn.body_params) do
        {:ok, instance} -> json(conn, 200, instance)
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
        {:error, _} -> json(conn, 422, %{error: "validation_failed"})
      end
    end)
  end

  delete "/os/:id" do
    with_auth(conn, fn _user_id ->
      case OsInstances.delete(id) do
        {:ok, _} -> json(conn, 200, %{status: "deleted"})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  post "/os/:id/enter" do
    with_auth(conn, fn user_id ->
      case OsInstances.enter(id, user_id) do
        {:ok, token_data} -> json(conn, 200, token_data)
        {:error, :not_member} -> json(conn, 403, %{error: "not_member"})
        {:error, _} -> json(conn, 500, %{error: "internal_error"})
      end
    end)
  end

  # ── OS members ──────────────────────────────────────────────────────

  get "/os/:id/members" do
    with_auth(conn, fn _user_id ->
      members = OsInstances.list_members(id)
      json(conn, 200, %{members: members, count: length(members)})
    end)
  end

  post "/os/:id/members" do
    with_auth(conn, fn _user_id ->
      user_id = conn.body_params["user_id"]
      role = conn.body_params["role"] || "member"

      case OsInstances.add_member(id, user_id, role) do
        {:ok, member} -> json(conn, 201, member)
        {:error, _} -> json(conn, 422, %{error: "validation_failed"})
      end
    end)
  end

  delete "/os/:id/members/:member_id" do
    with_auth(conn, fn _user_id ->
      case OsInstances.remove_member(id, member_id) do
        :ok -> json(conn, 200, %{status: "removed"})
      end
    end)
  end

  # ── Grants ──────────────────────────────────────────────────────────

  get "/grants" do
    with_auth(conn, fn _user_id ->
      os_id = conn.query_params["os_id"]

      if os_id do
        grants = Grants.list(os_id)
        json(conn, 200, %{grants: grants, count: length(grants)})
      else
        json(conn, 400, %{error: "os_id query param required"})
      end
    end)
  end

  post "/grants" do
    with_auth(conn, fn user_id ->
      attrs = Map.put(conn.body_params, "granted_by", user_id)

      case Grants.create(attrs) do
        {:ok, grant} -> json(conn, 201, grant)
        {:error, _} -> json(conn, 422, %{error: "validation_failed"})
      end
    end)
  end

  delete "/grants/:id" do
    with_auth(conn, fn _user_id ->
      case Grants.revoke(id) do
        {:ok, _} -> json(conn, 200, %{status: "revoked"})
        {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      end
    end)
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp with_auth(conn, fun) do
    if not platform_enabled?() do
      platform_unavailable(conn)
    else
      case conn.assigns[:claims] do
        %{"user_id" => user_id} -> fun.(user_id)
        _ -> json(conn, 401, %{error: "unauthorized"})
      end
    end
  end

  defp authorize_tenant_member(tenant_id, user_id, conn) do
    members = Tenants.list_members(tenant_id)

    if Enum.any?(members, fn m -> m.user_id == user_id end) do
      {:ok, tenant_id}
    else
      json(conn, 403, %{error: "forbidden", details: "Not a member of this tenant"})
      :error
    end
  end

  defp authorize_tenant_owner(tenant_id, user_id, conn) do
    members = Tenants.list_members(tenant_id)

    case Enum.find(members, fn m -> m.user_id == user_id end) do
      %{role: "owner"} ->
        {:ok, tenant_id}

      nil ->
        json(conn, 403, %{error: "forbidden", details: "Not a member of this tenant"})
        :error

      _ ->
        json(conn, 403, %{error: "forbidden", details: "Owner role required"})
        :error
    end
  end

  defp constraint_error_details(%Ecto.ConstraintError{constraint: constraint}) do
    field =
      case constraint do
        name when is_binary(name) ->
          name
          |> String.replace(~r/^.*_/, "")
          |> String.replace("_index", "")

        _ ->
          "field"
      end

    %{field => ["has already been taken"]}
  end
end
