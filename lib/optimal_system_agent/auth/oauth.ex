defmodule OptimalSystemAgent.Auth.OAuth do
  @moduledoc """
  OAuth 2.0 Authorization Code Flow with PKCE for Anthropic/Claude.

  Supports two auth paths:
  - Claude.ai OAuth (Pro/Max subscribers) → Bearer token for inference
  - Console OAuth → creates API key via OAuth

  Users choose between OAuth sign-in or pasting an API key during onboarding.
  """

  require Logger

  @authorize_url "https://console.anthropic.com/oauth/authorize"
  @token_url "https://console.anthropic.com/oauth/token"
  @api_key_url "https://api.anthropic.com/api/oauth/claude_cli/create_api_key"
  @profile_url "https://api.anthropic.com/api/oauth/profile"
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @redirect_path "/oauth/callback"

  @scopes ~w(org:create_api_key user:profile user:inference)

  @osa_dir Path.join(System.user_home!(), ".osa")

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Generate the authorization URL and PKCE verifier.

  Returns `{authorize_url, code_verifier, state}`.
  The caller must store `code_verifier` and `state` for the callback.
  """
  @spec authorize_url(String.t()) :: {String.t(), String.t(), String.t()}
  def authorize_url(redirect_uri) do
    code_verifier = generate_code_verifier()
    code_challenge = generate_code_challenge(code_verifier)
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    params =
      URI.encode_query(%{
        client_id: @client_id,
        response_type: "code",
        redirect_uri: redirect_uri,
        scope: Enum.join(@scopes, " "),
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        state: state
      })

    url = "#{@authorize_url}?#{params}"
    {url, code_verifier, state}
  end

  @doc """
  Exchange an authorization code for tokens.

  Returns `{:ok, %{access_token, refresh_token, expires_in, scope}}` or `{:error, reason}`.
  """
  @spec exchange_code(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def exchange_code(code, code_verifier, redirect_uri) do
    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: @client_id,
        code_verifier: code_verifier
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: resp}} ->
        tokens = %{
          access_token: resp["access_token"],
          refresh_token: resp["refresh_token"],
          expires_in: resp["expires_in"],
          scope: resp["scope"],
          expires_at: System.system_time(:second) + (resp["expires_in"] || 3600)
        }

        {:ok, tokens}

      {:ok, %{status: status, body: resp}} ->
        error = resp["error_description"] || resp["error"] || "HTTP #{status}"
        {:error, "Token exchange failed: #{error}"}

      {:error, reason} ->
        {:error, "Token exchange failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Refresh an expired access token.

  Returns `{:ok, updated_tokens}` or `{:error, reason}`.
  """
  @spec refresh_token(String.t()) :: {:ok, map()} | {:error, String.t()}
  def refresh_token(refresh_token) do
    body =
      URI.encode_query(%{
        grant_type: "refresh_token",
        refresh_token: refresh_token,
        client_id: @client_id,
        scope: Enum.join(@scopes, " ")
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case Req.post(@token_url, body: body, headers: headers) do
      {:ok, %{status: 200, body: resp}} ->
        tokens = %{
          access_token: resp["access_token"],
          refresh_token: resp["refresh_token"] || refresh_token,
          expires_in: resp["expires_in"],
          scope: resp["scope"],
          expires_at: System.system_time(:second) + (resp["expires_in"] || 3600)
        }

        {:ok, tokens}

      {:ok, %{status: status, body: resp}} ->
        error = resp["error_description"] || resp["error"] || "HTTP #{status}"
        {:error, "Token refresh failed: #{error}"}

      {:error, reason} ->
        {:error, "Token refresh failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Create an API key from an OAuth access token (Console users).

  This gives us a standard `sk-ant-*` key we can use like any other API key.
  Returns `{:ok, api_key}` or `{:error, reason}`.
  """
  @spec create_api_key(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def create_api_key(access_token) do
    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"content-type", "application/json"}
    ]

    case Req.post(@api_key_url, json: %{}, headers: headers) do
      {:ok, %{status: 200, body: %{"raw_key" => key}}} ->
        {:ok, key}

      {:ok, %{status: status, body: resp}} ->
        {:error, "API key creation failed (#{status}): #{inspect(resp)}"}

      {:error, reason} ->
        {:error, "API key creation failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetch user profile from an OAuth access token.

  Returns `{:ok, %{email, name, subscription_type}}` or `{:error, reason}`.
  """
  @spec fetch_profile(String.t()) :: {:ok, map()} | {:error, String.t()}
  def fetch_profile(access_token) do
    headers = [{"authorization", "Bearer #{access_token}"}]

    case Req.get(@profile_url, headers: headers) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, %{
          email: resp["email"],
          name: resp["name"],
          subscription_type: resp["subscription_type"]
        }}

      {:ok, %{status: status}} ->
        {:error, "Profile fetch failed (#{status})"}

      {:error, reason} ->
        {:error, "Profile fetch failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Get a valid access token, refreshing if expired.

  Reads from stored OAuth credentials, refreshes if within 5 minutes of expiry.
  Returns `{:ok, access_token}` or `{:error, reason}`.
  """
  @spec get_valid_token() :: {:ok, String.t()} | {:error, String.t()}
  def get_valid_token do
    case read_oauth_credentials() do
      {:ok, creds} ->
        now = System.system_time(:second)
        expires_at = creds["expires_at"] || 0

        if now + 300 >= expires_at do
          case refresh_token(creds["refresh_token"]) do
            {:ok, new_tokens} ->
              save_oauth_credentials(new_tokens)
              {:ok, new_tokens.access_token}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:ok, creds["access_token"]}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Storage ─────────────────────────────────────────────────────────

  @doc "Save OAuth credentials to ~/.osa/oauth.json"
  @spec save_oauth_credentials(map()) :: :ok
  def save_oauth_credentials(tokens) do
    File.mkdir_p!(@osa_dir)
    path = Path.join(@osa_dir, "oauth.json")
    data = Jason.encode!(tokens, pretty: true)
    File.write!(path, data)
    # Restrict permissions
    File.chmod!(path, 0o600)
    :ok
  end

  @doc "Read OAuth credentials from ~/.osa/oauth.json"
  @spec read_oauth_credentials() :: {:ok, map()} | {:error, String.t()}
  def read_oauth_credentials do
    path = Path.join(@osa_dir, "oauth.json")

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, creds} -> {:ok, creds}
          {:error, _} -> {:error, "Invalid oauth.json"}
        end

      {:error, :enoent} ->
        {:error, "No OAuth credentials found"}

      {:error, reason} ->
        {:error, "Failed to read oauth.json: #{inspect(reason)}"}
    end
  end

  @doc "Check if OAuth credentials exist and are valid."
  @spec oauth_configured?() :: boolean()
  def oauth_configured? do
    case read_oauth_credentials() do
      {:ok, %{"access_token" => token}} when is_binary(token) and token != "" -> true
      _ -> false
    end
  end

  @doc "Delete stored OAuth credentials."
  @spec clear_credentials() :: :ok
  def clear_credentials do
    path = Path.join(@osa_dir, "oauth.json")
    File.rm(path)
    :ok
  end

  # ── PKCE ────────────────────────────────────────────────────────────

  defp generate_code_verifier do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp generate_code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end
end
