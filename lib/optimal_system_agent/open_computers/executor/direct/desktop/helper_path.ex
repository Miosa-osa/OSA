defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.Desktop.HelperPath do
  @moduledoc """
  Resolves the native screen-capture helper binary.

  ## Why the ordering matters

  The helper is spawned on every desktop capture, with the user's full
  privileges, and it reads the screen and injects input. The previous lookup
  order tried a user-writable directory (`~/.osa/helpers`,
  `%USERPROFILE%\\.osa\\helpers`) BEFORE the binary bundled in the release, so
  any process running as the user — including a sandboxed one that can only
  write files — could drop an executable there and have OSA run it.

  The bundled binary in `priv/helpers` now wins. A user-supplied override is
  still possible, but it is opt-in and must match a pinned hash:

      OSA_DESKTOP_HELPER_OVERRIDE=/path/to/osa-screen-capture-darwin
      OSA_DESKTOP_HELPER_SHA256=<hex sha256 of that file>

  Both are required. A mismatch is refused and logged — never silently
  downgraded to the bundled binary, because a mismatch means someone replaced
  a file the operator pinned.
  """

  require Logger

  @override_path_env "OSA_DESKTOP_HELPER_OVERRIDE"
  @override_hash_env "OSA_DESKTOP_HELPER_SHA256"

  @doc """
  Return `{:ok, path}` for the helper to spawn, or `{:error, reason}`.

  Order: verified explicit override, then the bundled `priv` binary. The
  `user_path` argument is accepted only so the error message can mention it;
  it is never spawned without a hash match.
  """
  @spec resolve(String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(helper_name, priv_path, user_path, doc_ref) do
    case override() do
      {:ok, path} ->
        {:ok, path}

      {:error, reason} ->
        {:error, {:untrusted_helper, reason}}

      :none ->
        if File.exists?(priv_path) do
          {:ok, priv_path}
        else
          {:error, {:missing_helper, missing_message(helper_name, user_path, doc_ref)}}
        end
    end
  end

  @doc """
  Resolve the pinned override, if the operator configured one.

  Returns `:none` when no override is configured, `{:ok, path}` when it exists
  and its sha256 matches the pin, `{:error, reason}` otherwise.
  """
  @spec override() :: {:ok, String.t()} | {:error, String.t()} | :none
  def override do
    path = blank_to_nil(System.get_env(@override_path_env))
    pin = path && blank_to_nil(System.get_env(@override_hash_env))

    cond do
      is_nil(path) ->
        :none

      is_nil(pin) ->
        refuse(
          "#{@override_path_env} is set but #{@override_hash_env} is not. " <>
            "An unpinned helper override is not executed."
        )

      not File.exists?(path) ->
        refuse("#{@override_path_env}=#{path} does not exist.")

      true ->
        actual = sha256_file(path)

        if secure_compare(actual, String.downcase(pin)) do
          {:ok, path}
        else
          refuse(
            "#{@override_path_env}=#{path} does not match #{@override_hash_env} " <>
              "(actual #{actual}). Refusing to execute it."
          )
        end
    end
  end

  @doc "Hex sha256 of a file's contents."
  @spec sha256_file(String.t()) :: String.t()
  def sha256_file(path) do
    path
    |> File.stream!(2048, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # ── Private ──

  defp refuse(message) do
    Logger.error("[Desktop.HelperPath] #{message}")
    {:error, message}
  end

  defp missing_message(helper_name, user_path, doc_ref) do
    hint =
      if user_path do
        " A file at #{user_path} is NOT used unless pinned via " <>
          "#{@override_path_env}/#{@override_hash_env}."
      else
        ""
      end

    "#{helper_name} not found in the bundled priv/helpers. " <>
      "Install via: osa opencomputers install-helper (see #{doc_ref})." <> hint
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: String.trim(v)

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end
