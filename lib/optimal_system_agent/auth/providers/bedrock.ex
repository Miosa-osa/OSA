defmodule OptimalSystemAgent.Auth.Providers.Bedrock do
  @moduledoc """
  Connect Amazon Bedrock using the AWS credentials the machine already has.

  ## This is an account connection, not an OAuth flow

  There is no browser, no client id and no device code. Bedrock's "connect my
  account" mode means: use the credential chain the AWS CLI uses, sign each
  request with SigV4, and bill to the operator's AWS account. It implements
  `Auth.Subscription` anyway, for the same reason `claude_cli` and
  `ollama_account` do — every setup surface asks every non-key provider the
  same four questions (connect / status / token / sign out) and gets an answer
  in the same shape.

  ## OSA holds no AWS secret. Ever.

  The marker written to `subscriptions.json` records **which source answered**
  and **which region** — never an access key, never a secret, never a session
  token. Those stay where AWS put them (the environment, or
  `~/.aws/credentials`), are re-read live at request time, and are owned by
  the AWS tooling that wrote them.

  That is not squeamishness, it is the only correct design here. An AWS secret
  access key is a credential for an entire cloud account, not for one model
  API; copying it into a second file would (a) create a second thing to leak,
  (b) go stale the moment the user rotates it, and (c) silently keep working
  after they revoked it everywhere else. Re-reading the chain means OSA's
  access ends exactly when AWS's does.

  A consequence worth stating: `access_token/0` returns
  `{:error, :externally_managed}`. There is no bearer token to hand out —
  authentication is a per-request signature, so the transport asks for a
  `credential/0` and signs.

  ## Verification costs nothing

  Connecting verifies against `ListFoundationModels` on the Bedrock **control
  plane** (`bedrock.<region>.amazonaws.com`), not the runtime plane. That call
  is not inference, is not metered per token, and returns the account's actual
  model catalogue — so one free request proves the credential signs correctly,
  proves the region is real, and populates the model picker. Probing
  `/invoke` instead would charge the operator for drawing a screen.

  ## The other mode

  Bedrock also accepts a bearer API key (`AWS_BEARER_TOKEN_BEDROCK`), which is
  why the catalog entry declares BOTH modes on ONE provider row rather than
  splitting it. The two differ only in the credential — same host, same model
  ids, same request shape — which is exactly the condition for a single entry
  with an in-flow fork.
  """

  @behaviour OptimalSystemAgent.Auth.Subscription

  require Logger

  alias OptimalSystemAgent.Auth.AwsCredentials
  alias OptimalSystemAgent.Auth.AwsSigV4
  alias OptimalSystemAgent.Auth.SubscriptionStore

  @provider_id "bedrock"
  @display_name "Amazon Bedrock"

  # The control plane. Distinct from the runtime plane
  # (`bedrock-runtime.<region>`) that inference goes to, and the distinction is
  # the whole reason the health check is free.
  @control_host "bedrock"
  @runtime_host "bedrock-runtime"

  # SigV4 service name. Both planes sign as `bedrock`, NOT as
  # `bedrock-runtime` — the host and the service name differ, which is an easy
  # and completely opaque way to produce `SignatureDoesNotMatch`.
  @service "bedrock"

  @spec provider_id() :: String.t()
  def provider_id, do: @provider_id

  @spec display_name() :: String.t()
  def display_name, do: @display_name

  @doc """
  Sign-in is always offerable: it needs no registration and no client id, only
  credentials the user may or may not have. Whether they *do* is answered by
  attempting it, with a failure that names every place OSA looked.
  """
  @spec available?() :: boolean()
  def available?, do: true

  @doc "Runtime-plane base URL for a region."
  @spec runtime_url(String.t()) :: String.t()
  def runtime_url(region), do: "https://#{@runtime_host}.#{region}.amazonaws.com"

  @doc "Control-plane base URL for a region."
  @spec control_url(String.t()) :: String.t()
  def control_url(region), do: "https://#{@control_host}.#{region}.amazonaws.com"

  @doc "The SigV4 service name both Bedrock planes sign as."
  @spec service() :: String.t()
  def service, do: @service

  # ── Sign-in ───────────────────────────────────────────────────────────────

  @impl true
  @spec login(keyword()) :: {:ok, map()} | {:error, term()}
  def login(opts \\ []) do
    io = Keyword.get(opts, :io, &IO.puts/1)

    io.("")
    io.("  Looking for AWS credentials…")

    case connect() do
      {:ok, entry} ->
        io.("")
        io.("  ✓ Connected to #{@display_name} in #{entry["region"]}")
        io.("    Credential source: #{entry["source"]}")
        io.("    #{entry["model_count"]} foundation models available to this account")
        {:ok, entry}

      {:error, reason} = err ->
        io.("")
        io.("  #{message(reason)}")
        err
    end
  end

  @doc """
  Verify the credential chain and record the marker.

  This is what the **setup** surfaces call. It may create the marker; that is
  the point of a setup step. `live_status/0` may not.
  """
  @spec connect() :: {:ok, map()} | {:error, term()}
  def connect do
    with {:ok, creds} <- AwsCredentials.resolve(),
         {:ok, region} <- AwsCredentials.region(),
         {:ok, models} <- list_foundation_models(creds, region) do
      persist(creds, region, models)
    end
  end

  @doc """
  Live connection state, re-checked against AWS.

  Refuses to create a marker that is not already there. A status surface that
  connected as a side effect of rendering would resurrect the credential a
  user had just removed with `osa auth logout`, which is the bug that makes
  signing out appear to do nothing.
  """
  @spec live_status() :: {:ok, map()} | {:error, term()}
  def live_status do
    if is_nil(SubscriptionStore.fetch(@provider_id)) do
      {:error, :not_connected}
    else
      connect()
    end
  end

  defp persist(creds, region, models) do
    entry = %{
      "kind" => "aws_credential_chain",
      # Deliberately NO access_key_id, secret_access_key or session_token.
      # See the moduledoc: OSA stores where the credential came from, not the
      # credential. The last four characters of the key ID are kept because
      # "which AWS account am I actually on" is the single most common Bedrock
      # confusion, and a key id is not secret.
      "source" => creds.source,
      "access_key_hint" => String.slice(creds.access_key_id, -4, 4),
      "temporary?" => is_binary(creds[:session_token]),
      "region" => region,
      "base_url" => runtime_url(region),
      "model_count" => length(models),
      "connected_at" => System.system_time(:second),
      "issued_by" => OptimalSystemAgent.Auth.DeviceFlow.user_agent()
    }

    case SubscriptionStore.put(@provider_id, entry) do
      :ok -> {:ok, entry}
      err -> err
    end
  end

  # ── Status (pure read) ────────────────────────────────────────────────────

  @impl true
  def status do
    case SubscriptionStore.fetch(@provider_id) do
      nil ->
        OptimalSystemAgent.Auth.Subscription.disconnected(@provider_id)

      entry ->
        %{
          connected?: true,
          # The marker is only written after a signed ListFoundationModels
          # call succeeded, so its existence is real evidence — not merely
          # "an AWS config file exists on this box".
          verified?: true,
          provider: @provider_id,
          account: account_label(entry),
          plan: entry["region"],
          # A credential OSA does not hold has no expiry OSA can know. Session
          # credentials DO expire, and inventing a number here would make the
          # status line confidently wrong at exactly the moment it matters.
          expires_at: nil,
          expired?: false
        }
    end
  end

  defp account_label(%{"access_key_hint" => hint}) when is_binary(hint), do: "…#{hint}"
  defp account_label(_), do: nil

  # ── Credential resolution ─────────────────────────────────────────────────

  @doc """
  There is no bearer token. Saying so explicitly is the contract.

  A caller that wants one is about to put an AWS secret in an `Authorization`
  header, which is not how SigV4 works and would fail in a way that looks like
  a credential problem rather than a design mistake.
  """
  @impl true
  def access_token, do: {:error, :externally_managed}

  @doc """
  Everything the transport needs for one signed request: a live credential,
  the region, and the endpoint pinned at connect time.

  Resolved **live from the chain on every call**, never from the store. If the
  user rotates or revokes their key, the next request fails — which is the
  correct and expected behaviour for a credential OSA is borrowing rather than
  holding.

  The `base_url` is taken from the marker rather than recomputed, so a
  `*_URL`-shaped override from an untrusted workspace cannot redirect a signed
  AWS request to another host. It still has to agree with the region the
  signature is scoped to, so a mismatch fails at AWS rather than leaking.
  """
  @spec credential() :: {:ok, map()} | {:error, term()}
  def credential do
    entry = SubscriptionStore.fetch(@provider_id)

    with {:ok, creds} <- AwsCredentials.resolve(),
         {:ok, region} <- resolve_region(entry) do
      {:ok,
       %{
         credentials: creds,
         region: region,
         service: @service,
         base_url: (entry && entry["base_url"]) || runtime_url(region)
       }}
    end
  end

  # The region recorded at connect time wins over the ambient environment. A
  # user who connected in `eu-central-1` and later has `AWS_REGION` set to
  # something else by an unrelated tool should keep talking to the endpoint
  # their models are actually in, rather than silently moving account.
  defp resolve_region(%{"region" => r}) when is_binary(r) and r != "", do: {:ok, r}
  defp resolve_region(_), do: AwsCredentials.region()

  # ── The free verification call ────────────────────────────────────────────

  @doc """
  List the foundation models this account can use.

  Control plane, so it is not inference and not metered per token. Used both
  as the connection check and as the source of the model picker's catalogue —
  one request answering both questions, rather than a probe whose only output
  is a tick.
  """
  @spec list_foundation_models(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_foundation_models(creds, region) do
    url = control_url(region) <> "/foundation-models"

    headers =
      AwsSigV4.sign("GET", url, [{"accept", "application/json"}], "", creds,
        region: region,
        service: @service
      )

    case Req.get(req_options(url: url, headers: headers)) do
      {:ok, %{status: 200, body: %{"modelSummaries" => models}}} when is_list(models) ->
        {:ok, models}

      {:ok, %{status: 200}} ->
        # A 200 with no summaries is a real state (an account with nothing
        # enabled), not a parse failure. Honest zero, not a fabricated list.
        {:ok, []}

      {:ok, %{status: 403, body: body}} ->
        {:error, {:aws_forbidden, aws_message(body)}}

      {:ok, %{status: status, body: body}} when status in [400, 401] ->
        {:error, {:aws_rejected, status, aws_message(body)}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:aws_http_error, status, aws_message(body)}}

      {:error, e} ->
        {:error, {:transport_error, Exception.message(e)}}
    end
  rescue
    e -> {:error, {:transport_error, Exception.message(e)}}
  end

  defp req_options(extra) do
    Keyword.merge(
      [receive_timeout: 30_000, retry: false] ++ extra,
      Application.get_env(:optimal_system_agent, :auth_req_options, [])
    )
  end

  @doc false
  @spec aws_message(term()) :: String.t()
  def aws_message(%{"message" => m}) when is_binary(m), do: m
  def aws_message(%{"Message" => m}) when is_binary(m), do: m
  def aws_message(body) when is_binary(body), do: String.slice(body, 0, 300)
  def aws_message(_), do: "no detail returned"

  # ── Sign-out ──────────────────────────────────────────────────────────────

  @doc """
  Forget the connection.

  **Nothing is revoked remotely, and that is correct here rather than a gap.**
  AWS exposes no endpoint that revokes a long-lived IAM access key on request
  — revoking one means deleting or deactivating it in IAM, which would destroy
  the user's credential for every other AWS tool on the machine, not just for
  OSA. So the honest scope of this action is local, and the log line says so
  instead of implying an account-level change happened.
  """
  @impl true
  def logout do
    was_connected? = not is_nil(SubscriptionStore.fetch(@provider_id))
    result = SubscriptionStore.delete(@provider_id)

    if was_connected? do
      Logger.info(
        "[Auth] Disconnected #{@display_name} from OSA. Your AWS credentials are untouched — " <>
          "OSA never held them, and nothing was revoked in IAM."
      )
    end

    result
  end

  # ── Messages ──────────────────────────────────────────────────────────────

  @doc """
  A failure reason as one actionable explanation.

  Kept here rather than in `Auth.Subscription.message/2` for the AWS-specific
  reasons only, because every one of them ends in a different AWS concept
  (a chain, a region, an IAM policy) and the generic "paste an API key
  instead" tail would be wrong advice for most of them.
  """
  @spec message(term()) :: String.t()
  def message({:aws_no_credentials, _} = reason), do: AwsCredentials.explain(reason)
  def message({:aws_no_region, _, _} = reason), do: AwsCredentials.explain(reason)

  def message({:aws_forbidden, detail}),
    do:
      "AWS accepted the signature but refused the request: #{detail} " <>
        "The credential is valid — this is an IAM permissions problem. The identity needs " <>
        "`bedrock:ListFoundationModels` and `bedrock:InvokeModel` (add `bedrock:Converse` " <>
        "and `bedrock:ConverseStream` if your policy lists actions individually)."

  def message({:aws_rejected, _status, detail}),
    do:
      "AWS rejected the request: #{detail} " <>
        "This usually means the credential is expired or mistyped, or the clock on this machine " <>
        "is more than a few minutes off — SigV4 signatures are time-bound."

  def message({:aws_http_error, status, detail}),
    do: "Amazon Bedrock returned HTTP #{status}: #{detail}"

  def message({:transport_error, detail}),
    do:
      "Could not reach Amazon Bedrock (#{detail}). Check your connection, and check the region " <>
        "is one Bedrock actually serves."

  def message(:not_connected),
    do: "Amazon Bedrock is not connected. Run `osa setup` and choose Amazon Bedrock."

  def message(other), do: OptimalSystemAgent.Auth.Subscription.message(other, @display_name)
end
