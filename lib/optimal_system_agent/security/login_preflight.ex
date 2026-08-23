defmodule OptimalSystemAgent.Security.LoginPreflight do
  @moduledoc """
  Gate: do we have an authenticated session artifact before IDOR/authz classes?

  Authenticated testing must log in *before* authorization checks. This module
  is not a browser driver. It only answers whether cookies, Authorization,
  Playwright `storage_state`, or a session token are present. Fail closed:
  missing artifact blocks classes that require a logged-in user.

  No Playwright install. No network. No Mix deps.
  """

  @no_artifact "login preflight failed: no session artifact (cookies/authorization/storage_state)"

  @requires_login MapSet.new([
                    :idor,
                    :auth_bypass,
                    :csrf,
                    :business_logic,
                    :authz,
                    :bac
                  ])

  @doc """
  True when the session map carries any authenticated artifact.

  Accepts atom or string keys: `cookies`, `headers`, `storage_state`,
  `session_token`.
  """
  @spec check(map()) :: {:ok, :authenticated} | {:error, String.t()}
  def check(session) when is_map(session) do
    if authenticated?(session) do
      {:ok, :authenticated}
    else
      {:error, @no_artifact}
    end
  end

  def check(_), do: {:error, @no_artifact}

  @doc """
  True for classes that are meaningless without a logged-in user
  (`:idor`, `:auth_bypass`, `:csrf`, `:business_logic`, `:authz`, `:bac`).
  """
  @spec required_for?(atom()) :: boolean()
  def required_for?(class) when is_atom(class), do: MapSet.member?(@requires_login, class)
  def required_for?(_), do: false

  @doc "Run `check/1` when the class requires login; otherwise `:ok`."
  @spec assert_for(atom(), map()) :: :ok | {:error, String.t()}
  def assert_for(class, session) when is_atom(class) and is_map(session) do
    if required_for?(class) do
      case check(session) do
        {:ok, :authenticated} -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  def assert_for(class, _) when is_atom(class) do
    if required_for?(class), do: {:error, @no_artifact}, else: :ok
  end

  defp authenticated?(session) do
    cookies?(field(session, :cookies)) or
      headers?(field(session, :headers)) or
      storage_state?(field(session, :storage_state)) or
      session_token?(field(session, :session_token))
  end

  defp cookies?(cookies) when is_binary(cookies) and cookies != "" do
    String.contains?(cookies, "=")
  end

  defp cookies?(cookies) when is_map(cookies) do
    Enum.any?(cookies, &name_value_pair?/1)
  end

  defp cookies?(cookies) when is_list(cookies) do
    Enum.any?(cookies, &name_value_pair?/1)
  end

  defp cookies?(_), do: false

  defp headers?(headers) when is_map(headers) do
    Enum.any?(headers, &auth_or_cookie_header?/1)
  end

  defp headers?(headers) when is_list(headers) do
    Enum.any?(headers, &auth_or_cookie_header?/1)
  end

  defp headers?(_), do: false

  defp auth_or_cookie_header?({key, value}) do
    present?(value) and header_name(key) in ["authorization", "cookie"]
  end

  defp auth_or_cookie_header?(_), do: false

  defp header_name(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp header_name(key) when is_binary(key), do: String.downcase(key)
  defp header_name(_), do: ""

  defp storage_state?(state) when is_map(state) do
    cookies_list_present?(field(state, :cookies) || Map.get(state, "cookies"))
  end

  defp storage_state?(path) when is_binary(path) and path != "" do
    with true <- File.regular?(path),
         {:ok, bin} <- File.read(path),
         {:ok, decoded} <- Jason.decode(bin) do
      storage_state?(decoded)
    else
      _ -> false
    end
  end

  defp storage_state?(_), do: false

  defp cookies_list_present?(cookies) when is_list(cookies) and cookies != [] do
    Enum.any?(cookies, &name_value_pair?/1)
  end

  defp cookies_list_present?(_), do: false

  defp session_token?(token) when is_binary(token), do: String.trim(token) != ""
  defp session_token?(_), do: false

  defp name_value_pair?({name, value}), do: present?(name) and present?(value)

  defp name_value_pair?(item) when is_map(item) do
    present?(field(item, :name) || field(item, :key)) and
      present?(field(item, :value))
  end

  defp name_value_pair?(_), do: false

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: true
end
