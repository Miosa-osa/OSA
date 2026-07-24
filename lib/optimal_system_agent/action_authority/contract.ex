defmodule OptimalSystemAgent.ActionAuthority.Contract do
  @moduledoc """
  Generated identity aliases for OSA actions backed by the MIOSA platform.

  This module deliberately owns no authorization policy.
  Risk, scope, approval posture, grants, and limits remain server-owned.
  """

  @contract_path Path.expand("../../../priv/action-capabilities.json", __DIR__)
  @external_resource @contract_path

  @contract @contract_path
            |> File.read!()
            |> Jason.decode!()

  @osa_aliases @contract
               |> Map.fetch!("capabilities")
               |> Enum.flat_map(fn capability ->
                 capability
                 |> get_in(["surfaces", "osa"])
                 |> List.wrap()
                 |> Enum.map(&{&1, capability["name"]})
               end)
               |> Map.new()

  @doc "Returns the canonical capability for one exact OSA surface alias."
  @spec capability_for(String.t()) :: {:ok, String.t()} | {:error, :unknown_alias}
  def capability_for(alias_name) when is_binary(alias_name) do
    case Map.fetch(@osa_aliases, alias_name) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, :unknown_alias}
    end
  end

  def capability_for(_alias_name), do: {:error, :unknown_alias}

  @doc "Returns all generated OSA aliases for conformance diagnostics."
  @spec osa_aliases() :: %{String.t() => String.t()}
  def osa_aliases, do: @osa_aliases
end
