defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.SessionGrant do
  @moduledoc """
  One-use desktop authorization attested by the authenticated control plane.
  The platform verifies its signed ticket and owner before sending this separate
  frame. Job payloads are not authority. No platform HMAC key is shared with OSA.
  Grants are connection-bound, capped at five minutes, and never persisted.
  """

  def accept(grant, state) do
    now = System.system_time(:second)

    grants =
      Map.get(state, :desktop_grants, %{}) |> Map.reject(fn {_, g} -> g.expires_at <= now end)

    used = Map.get(state, :desktop_grants_used, %{}) |> Map.reject(fn {_, exp} -> exp <= now end)

    valid =
      state[:phase] == :active and state[:verified_control] === true and
        is_binary(state[:host_id]) and is_binary(state[:owner_tenant_id]) and
        grant[:host_id] == state[:host_id] and grant[:tenant_id] == state[:owner_tenant_id] and
        is_binary(grant[:session_id]) and byte_size(grant.session_id) in 1..128 and
        is_integer(grant[:expires_at]) and grant.expires_at > now and
        grant.expires_at <= now + 300 and
        is_list(grant[:scope]) and "desktop:stream" in grant.scope

    if valid and map_size(grants) + map_size(used) < 32 and
         not Map.has_key?(grants, grant.session_id) and not Map.has_key?(used, grant.session_id),
       do:
         Map.merge(state, %{
           desktop_grants: Map.put(grants, grant.session_id, grant),
           desktop_grants_used: used
         }),
       else: state
  end

  def consume(request, state) do
    {grant, grants} = Map.pop(Map.get(state, :desktop_grants, %{}), request[:session_id])
    state = Map.put(state, :desktop_grants, grants)

    if grant && state[:verified_control] === true && state[:phase] == :active &&
         grant.host_id == state[:host_id] && grant.tenant_id == state[:owner_tenant_id] &&
         grant.expires_at > System.system_time(:second) &&
         request[:tenant_id] == grant.tenant_id do
      owner = self()
      ttl = max(grant.expires_at * 1000 - System.system_time(:millisecond), 0)

      lease =
        spawn(fn ->
          ref = Process.monitor(owner)

          receive do
            :revoke -> :ok
            {:DOWN, ^ref, :process, ^owner, _} -> :ok
          after
            ttl -> :ok
          end
        end)

      leases =
        Map.get(state, :desktop_leases, %{}) |> Map.filter(fn {_, pid} -> Process.alive?(pid) end)

      context = [input_authorized: "desktop:control" in grant.scope, desktop_lease: lease]

      used =
        Map.put(Map.get(state, :desktop_grants_used, %{}), grant.session_id, grant.expires_at)

      {context,
       Map.merge(state, %{
         desktop_leases: Map.put(leases, grant.session_id, lease),
         desktop_grants_used: used
       })}
    else
      {[], state}
    end
  end

  def revoke(state, session_id) do
    {lease, leases} = Map.pop(Map.get(state, :desktop_leases, %{}), session_id)
    if lease, do: send(lease, :revoke)

    Map.merge(state, %{
      desktop_leases: leases,
      desktop_grants: Map.delete(Map.get(state, :desktop_grants, %{}), session_id)
    })
  end

  def clear(state) do
    Enum.each(Map.get(state, :desktop_leases, %{}), fn {_, pid} -> send(pid, :revoke) end)

    Map.merge(state, %{
      desktop_grants: %{},
      desktop_grants_used: %{},
      desktop_leases: %{},
      verified_control: false,
      host_id: nil,
      owner_tenant_id: nil
    })
  end
end
