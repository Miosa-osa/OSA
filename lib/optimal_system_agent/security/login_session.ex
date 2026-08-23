defmodule OptimalSystemAgent.Security.LoginSession do
  @moduledoc """
  Session store for Playwright login artifacts.

  This is not a browser driver. It captures cookies, headers, Playwright
  `storage_state`, and session tokens so `LoginPreflight.check/1` can
  answer whether an authenticated session exists. Fail closed: classes
  that need a logged-in user (`:idor`, `:auth_bypass`, `:csrf`,
  `:business_logic`, `:authz`, `:bac`) error when no artifact is stored.

  Named ETS table `:osa_security_login`, keyed by `session_id`.
  No Playwright install. No network. No Mix deps.
  """

  @table :osa_security_login
  @no_session "no login session"
  @no_cookies "no cookies in login session"
  @no_artifact "login session requires cookies, headers, storage_state, or token"
  @no_preflight "login preflight failed: no session artifact (cookies/authorization/storage_state)"
  @bad_storage "storage_state is not a readable JSON file"

  @requires_login MapSet.new([
                    :idor,
                    :auth_bypass,
                    :csrf,
                    :business_logic,
                    :authz,
                    :bac
                  ])

  @type record :: %{
          cookies: String.t() | nil,
          headers: map(),
          storage_state: map() | nil,
          token: String.t() | nil,
          updated_at: DateTime.t()
        }

  @doc """
  Store session artifacts for `session_id`.

  Accepts atom or string keys: `cookies`, `headers`, `storage_state`,
  `session_token` / `token`. Cookies may be a `name=value` binary, a list
  of `%{name, value}` maps, or a Playwright cookies array. A `storage_state`
  path is read as JSON and stored as a map.

  At least one artifact is required.
  """
  @spec put(String.t(), map()) :: {:ok, record()} | {:error, String.t()}
  def put(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    ensure_table()

    with {:ok, cookies} <- take_cookies(attrs),
         {:ok, headers} <- take_headers(attrs),
         {:ok, storage_state} <- take_storage_state(attrs),
         {:ok, token} <- take_token(attrs) do
      rec = %{
        cookies: cookies,
        headers: headers,
        storage_state: storage_state,
        token: token,
        updated_at: DateTime.utc_now()
      }

      if has_artifact?(rec) do
        :ets.insert(@table, {session_id, rec})
        {:ok, rec}
      else
        {:error, @no_artifact}
      end
    end
  end

  def put(_, _), do: {:error, @no_artifact}

  @doc "Return the stored record for `session_id`."
  @spec get(String.t()) :: {:ok, record()} | {:error, String.t()}
  def get(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, rec}] -> {:ok, rec}
      [] -> {:error, @no_session}
    end
  end

  @doc """
  Artifact map in the shape `LoginPreflight.check/1` expects.

  Missing sessions return empty fields so the preflight fails closed.
  """
  @spec artifact_map(String.t()) :: map()
  def artifact_map(session_id) when is_binary(session_id) do
    case get(session_id) do
      {:ok, rec} -> to_artifacts(rec)
      {:error, _} -> empty_artifacts()
    end
  end

  @doc "Cookie header for `session_id` as `a=b; c=d`."
  @spec cookie_header(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def cookie_header(session_id) when is_binary(session_id) do
    case get(session_id) do
      {:ok, rec} ->
        cond do
          is_binary(rec.cookies) and rec.cookies != "" ->
            {:ok, rec.cookies}

          header = storage_cookie_header(rec.storage_state) ->
            {:ok, header}

          true ->
            {:error, @no_cookies}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Gate a vuln class against the stored session.

  Calls `LoginPreflight.assert_for/2` when that module is loaded.
  Otherwise uses the same required-login set.
  """
  @spec assert_ready(String.t(), atom()) :: :ok | {:error, String.t()}
  def assert_ready(session_id, class) when is_binary(session_id) and is_atom(class) do
    artifacts = artifact_map(session_id)

    case preflight_mod() do
      {:ok, mod} ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :assert_for, 2) do
          apply(mod, :assert_for, [class, artifacts])
        else
          fallback_assert(class, artifacts)
        end

      :error ->
        fallback_assert(class, artifacts)
    end
  end

  defp take_cookies(attrs) do
    case field(attrs, :cookies) do
      nil -> {:ok, nil}
      cookies -> normalize_cookies(cookies)
    end
  end

  defp take_headers(attrs) do
    case field(attrs, :headers) do
      nil -> {:ok, %{}}
      headers -> normalize_headers(headers)
    end
  end

  defp take_storage_state(attrs) do
    case field(attrs, :storage_state) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      state -> normalize_storage_state(state)
    end
  end

  defp take_token(attrs) do
    case field(attrs, :session_token) || field(attrs, :token) do
      token when is_binary(token) ->
        if String.trim(token) == "", do: {:ok, nil}, else: {:ok, token}

      nil ->
        {:ok, nil}

      _ ->
        {:error, "token must be a string"}
    end
  end

  defp normalize_cookies(cookies) when is_binary(cookies) and cookies != "" do
    if String.contains?(cookies, "=") do
      {:ok, cookies}
    else
      {:error, "cookies must contain '='"}
    end
  end

  defp normalize_cookies(cookies) when is_list(cookies) do
    case cookie_pairs(cookies) do
      [] ->
        {:ok, nil}

      pairs ->
        {:ok, Enum.map_join(pairs, "; ", fn {name, value} -> "#{name}=#{value}" end)}
    end
  end

  defp normalize_cookies(cookies) when is_map(cookies) do
    if field(cookies, :name) && field(cookies, :value) do
      normalize_cookies([cookies])
    else
      pairs =
        for {name, value} <- cookies,
            n = to_name(name),
            is_binary(n) and n != "" and is_binary(value) and value != "",
            do: {n, value}

      case pairs do
        [] -> {:ok, nil}
        _ -> {:ok, Enum.map_join(pairs, "; ", fn {n, v} -> "#{n}=#{v}" end)}
      end
    end
  end

  defp normalize_cookies(nil), do: {:ok, nil}
  defp normalize_cookies(""), do: {:ok, nil}
  defp normalize_cookies(_), do: {:error, "cookies must be a header string or name/value list"}

  defp normalize_headers(headers) when is_map(headers), do: {:ok, headers}

  defp normalize_headers(headers) when is_list(headers) do
    {:ok,
     Enum.reduce(headers, %{}, fn
       {key, value}, acc ->
         Map.put(acc, key, value)

       item, acc when is_map(item) ->
         name = field(item, :name) || field(item, :key)
         value = field(item, :value)

         if is_binary(name) and name != "", do: Map.put(acc, name, value), else: acc

       _, acc ->
         acc
     end)}
  end

  defp normalize_headers(_), do: {:error, "headers must be a map"}

  defp normalize_storage_state(state) when is_map(state), do: {:ok, state}

  defp normalize_storage_state(path) when is_binary(path) and path != "" do
    with true <- File.regular?(path),
         {:ok, bin} <- File.read(path),
         {:ok, decoded} <- decode_json(bin) do
      {:ok, decoded}
    else
      _ -> {:error, @bad_storage}
    end
  end

  defp normalize_storage_state(_), do: {:error, @bad_storage}

  defp decode_json(bin) do
    if Code.ensure_loaded?(Jason) and function_exported?(Jason, :decode, 1) do
      Jason.decode(bin)
    else
      {:error, @bad_storage}
    end
  end

  defp cookie_pairs(cookies) when is_list(cookies) do
    Enum.flat_map(cookies, fn
      {name, value} ->
        cookie_pair(name, value)

      item when is_map(item) ->
        cookie_pair(field(item, :name) || field(item, :key), field(item, :value))

      _ ->
        []
    end)
  end

  defp cookie_pair(name, value)
       when is_binary(name) and name != "" and is_binary(value) and value != "" do
    [{name, value}]
  end

  defp cookie_pair(_, _), do: []

  defp to_name(name) when is_atom(name), do: Atom.to_string(name)
  defp to_name(name) when is_binary(name), do: name
  defp to_name(_), do: nil

  defp has_artifact?(rec) do
    artifacts = to_artifacts(rec)

    case preflight_mod() do
      {:ok, mod} ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :check, 1) do
          match?({:ok, :authenticated}, apply(mod, :check, [artifacts]))
        else
          fallback_authenticated?(artifacts)
        end

      :error ->
        fallback_authenticated?(artifacts)
    end
  end

  defp to_artifacts(rec) do
    %{
      cookies: rec.cookies,
      headers: rec.headers || %{},
      storage_state: rec.storage_state,
      session_token: rec.token
    }
  end

  defp empty_artifacts do
    %{cookies: nil, headers: %{}, storage_state: nil, session_token: nil}
  end

  defp storage_cookie_header(state) when is_map(state) do
    cookies = field(state, :cookies) || Map.get(state, "cookies")

    case cookies do
      list when is_list(list) ->
        case cookie_pairs(list) do
          [] -> nil
          pairs -> Enum.map_join(pairs, "; ", fn {name, value} -> "#{name}=#{value}" end)
        end

      _ ->
        nil
    end
  end

  defp storage_cookie_header(_), do: nil

  defp preflight_mod do
    mod = OptimalSystemAgent.Security.LoginPreflight
    if Code.ensure_loaded?(mod), do: {:ok, mod}, else: :error
  end

  defp fallback_assert(class, session) do
    if MapSet.member?(@requires_login, class) do
      if fallback_authenticated?(session), do: :ok, else: {:error, @no_preflight}
    else
      :ok
    end
  end

  defp fallback_authenticated?(session) do
    cookies_present?(field(session, :cookies)) or
      headers_present?(field(session, :headers)) or
      storage_present?(field(session, :storage_state)) or
      token_present?(field(session, :session_token) || field(session, :token))
  end

  defp cookies_present?(cookies) when is_binary(cookies) and cookies != "",
    do: String.contains?(cookies, "=")

  defp cookies_present?(cookies) when is_list(cookies), do: cookie_pairs(cookies) != []
  defp cookies_present?(_), do: false

  defp headers_present?(headers) when is_map(headers) do
    Enum.any?(headers, fn {key, value} ->
      present?(value) and header_name(key) in ["authorization", "cookie"]
    end)
  end

  defp headers_present?(_), do: false

  defp storage_present?(state) when is_map(state) do
    cookies = field(state, :cookies) || Map.get(state, "cookies")
    is_list(cookies) and cookie_pairs(cookies) != []
  end

  defp storage_present?(_), do: false

  defp token_present?(token) when is_binary(token), do: String.trim(token) != ""
  defp token_present?(_), do: false

  defp header_name(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp header_name(key) when is_binary(key), do: String.downcase(key)
  defp header_name(_), do: ""

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: true

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
