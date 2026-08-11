defmodule OptimalSystemAgent.Auth.AwsCredentials do
  @moduledoc """
  Resolve AWS credentials and a region from the sources a developer already
  has configured, in the order AWS's own SDKs use them.

  ## The chain, and why every step is named on failure

  1. **Environment** — `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`, plus
     `AWS_SESSION_TOKEN` when the credential is temporary.
  2. **Shared credentials file** — `AWS_SHARED_CREDENTIALS_FILE`, else
     `~/.aws/credentials`, reading the profile named by `AWS_PROFILE` (else
     `default`).

  When both miss, the error carries **every source that was tried and what it
  said** — not a bare "no credentials". "AWS credentials not found" is one of
  the least actionable messages in computing: the user has four plausible
  places a credential could have come from and no idea which one OSA looked
  at, whether the file existed, or whether the profile name was wrong. So the
  failure distinguishes "the file is not there" from "the file is there and
  has no `[prod]` section" from "the section is there and has no
  `aws_secret_access_key`", and says which profile name it used and where it
  got that name.

  ## What is deliberately NOT supported

  `credential_process`, IAM Roles Anywhere, SSO token caches, EC2/ECS instance
  metadata (IMDS) and `assume_role` profile chaining are all absent. Each is a
  separate protocol, and a half-implementation that silently returns the wrong
  identity is worse than an honest gap — so a profile that uses one of them is
  **detected by name** and reported as unsupported with the workaround
  (`aws configure export-credentials`), rather than being read as if the
  static keys it lacks were merely missing.

  ## Reading `~/.aws/credentials`

  OSA reads this file in its own process, to sign its own requests, exactly as
  every AWS SDK does. That is unrelated to — and must not be confused with —
  the path being on the **agent tool** denylist, which stops a model-driven
  `file_read` from exfiltrating it. Those are different actors: the harness
  may use a credential, the agent may not read one. Nothing here relaxes the
  denylist and nothing here returns file contents to a caller: only a
  credential struct, which never crosses into tool output.
  """

  @default_region_env ~w(AWS_REGION AWS_DEFAULT_REGION)

  @typedoc "A credential plus the human-readable name of where it came from."
  @type resolved :: %{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          session_token: String.t() | nil,
          source: String.t()
        }

  @doc """
  Resolve a credential from the chain.

  Returns `{:ok, resolved}` or `{:error, {:aws_no_credentials, [attempt]}}`
  where each attempt is `{source_label, reason}`.
  """
  @spec resolve() :: {:ok, resolved()} | {:error, term()}
  def resolve do
    case from_env() do
      {:ok, creds} ->
        {:ok, creds}

      {:skip, env_reason} ->
        case from_shared_file() do
          {:ok, creds} -> {:ok, creds}
          {:skip, file_reason} -> {:error, {:aws_no_credentials, [env_reason, file_reason]}}
        end
    end
  end

  @doc """
  The AWS region, from `AWS_REGION`, `AWS_DEFAULT_REGION`, or the active
  profile's `region` in `~/.aws/config`.

  Bedrock has no global endpoint, so an absent region is a hard failure rather
  than a default — guessing `us-east-1` for a user whose models live in
  `eu-central-1` produces a `ValidationException` about the model id, which
  names the wrong problem entirely.
  """
  @spec region() :: {:ok, String.t()} | {:error, term()}
  def region do
    case Enum.find_value(@default_region_env, &present(System.get_env(&1))) do
      nil -> region_from_config_file()
      value -> {:ok, value}
    end
  end

  @doc "The profile name in use, and where that name came from."
  @spec profile_name() :: {String.t(), :env | :default}
  def profile_name do
    case present(System.get_env("AWS_PROFILE")) do
      nil -> {"default", :default}
      name -> {name, :env}
    end
  end

  @doc "Path of the shared credentials file OSA would read."
  @spec credentials_path() :: String.t()
  def credentials_path do
    case present(System.get_env("AWS_SHARED_CREDENTIALS_FILE")) do
      nil -> Path.join([home(), ".aws", "credentials"])
      path -> Path.expand(path)
    end
  end

  @doc "Path of the shared config file OSA would read for a region."
  @spec config_path() :: String.t()
  def config_path do
    case present(System.get_env("AWS_CONFIG_FILE")) do
      nil -> Path.join([home(), ".aws", "config"])
      path -> Path.expand(path)
    end
  end

  @doc """
  One line per credential source, for `osa doctor` and the setup surfaces.

  Contains **no secret material** — only which source answered and, for a key
  id (which is not a secret and appears in AWS's own console), its last four
  characters, which is what makes "wrong account" diagnosable without printing
  anything sensitive.
  """
  @spec describe() :: String.t()
  def describe do
    case resolve() do
      {:ok, %{source: source, access_key_id: id}} -> "#{source} (…#{String.slice(id, -4, 4)})"
      {:error, _} -> "no credential found"
    end
  end

  # ── Step 1: environment ───────────────────────────────────────────────────

  defp from_env do
    id = present(System.get_env("AWS_ACCESS_KEY_ID"))
    secret = present(System.get_env("AWS_SECRET_ACCESS_KEY"))

    cond do
      is_binary(id) and is_binary(secret) ->
        {:ok,
         %{
           access_key_id: id,
           secret_access_key: secret,
           session_token: present(System.get_env("AWS_SESSION_TOKEN")),
           source: "environment (AWS_ACCESS_KEY_ID)"
         }}

      is_binary(id) ->
        # Half a credential is a configuration mistake, not an absence, and
        # falling through to the file would quietly use a DIFFERENT account
        # than the one the user just exported.
        {:skip, {"environment", "AWS_ACCESS_KEY_ID is set but AWS_SECRET_ACCESS_KEY is not"}}

      true ->
        {:skip, {"environment", "AWS_ACCESS_KEY_ID is not set"}}
    end
  end

  # ── Step 2: the shared credentials file ───────────────────────────────────

  defp from_shared_file do
    path = credentials_path()
    {profile, origin} = profile_name()

    named =
      case origin do
        :env -> "profile #{profile} (from AWS_PROFILE)"
        :default -> "profile #{profile}"
      end

    label = "#{path} — #{named}"

    case read_ini(path) do
      {:error, :enoent} ->
        {:skip, {label, "file does not exist"}}

      {:error, reason} ->
        {:skip, {label, "could not be read (#{:file.format_error(reason)})"}}

      {:ok, sections} ->
        case Map.get(sections, profile) do
          nil ->
            {:skip, {label, "no [#{profile}] section in the file"}}

          entries ->
            from_profile_entries(entries, label)
        end
    end
  end

  defp from_profile_entries(entries, label) do
    id = present(entries["aws_access_key_id"])
    secret = present(entries["aws_secret_access_key"])

    cond do
      is_binary(id) and is_binary(secret) ->
        {:ok,
         %{
           access_key_id: id,
           secret_access_key: secret,
           session_token: present(entries["aws_session_token"]),
           source: label
         }}

      unsupported = unsupported_mechanism(entries) ->
        {:skip,
         {label,
          "uses #{unsupported}, which OSA does not implement. " <>
            "Run `aws configure export-credentials --profile <name> --format env` " <>
            "and export those variables instead."}}

      true ->
        {:skip, {label, "section exists but has no aws_access_key_id/aws_secret_access_key"}}
    end
  end

  # Named explicitly so the user is told their profile is a KIND OSA cannot
  # read, rather than being told their keys are missing when the profile was
  # never going to contain keys in the first place.
  defp unsupported_mechanism(entries) do
    cond do
      present(entries["credential_process"]) -> "credential_process"
      present(entries["sso_session"]) || present(entries["sso_start_url"]) -> "AWS SSO"
      present(entries["role_arn"]) -> "assume_role (role_arn)"
      true -> nil
    end
  end

  # ── region from ~/.aws/config ─────────────────────────────────────────────

  defp region_from_config_file do
    path = config_path()
    {profile, _} = profile_name()

    # `~/.aws/config` names non-default profiles `[profile NAME]`, while
    # `~/.aws/credentials` names them `[NAME]`. Getting this wrong is why a
    # region set in the config file appears to be ignored.
    keys = if profile == "default", do: ["default"], else: ["profile #{profile}", profile]

    with {:ok, sections} <- read_ini(path),
         entries when is_map(entries) <- Enum.find_value(keys, &Map.get(sections, &1)),
         value when is_binary(value) <- present(entries["region"]) do
      {:ok, value}
    else
      _ -> {:error, {:aws_no_region, path, profile}}
    end
  end

  # ── a small INI reader ────────────────────────────────────────────────────

  @doc false
  @spec read_ini(String.t()) ::
          {:ok, %{String.t() => %{String.t() => String.t()}}} | {:error, term()}
  def read_ini(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, parse_ini(content)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_ini(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce({nil, %{}}, fn raw, {section, acc} ->
      line = raw |> strip_comment() |> String.trim()

      cond do
        line == "" ->
          {section, acc}

        String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
          name = line |> String.slice(1..-2//1) |> String.trim()
          {name, Map.put_new(acc, name, %{})}

        is_nil(section) ->
          {section, acc}

        true ->
          case String.split(line, "=", parts: 2) do
            [k, v] ->
              key = k |> String.trim() |> String.downcase()

              {section,
               update_in(acc, [Access.key(section, %{})], &Map.put(&1, key, String.trim(v)))}

            _ ->
              {section, acc}
          end
      end
    end)
    |> elem(1)
  end

  # `;` and `#` start a comment only at the start of a line or after
  # whitespace — a `#` inside a secret is a legal character, and treating it as
  # a comment silently truncates the key, which presents as
  # `SignatureDoesNotMatch` and sends the user hunting for a clock problem.
  defp strip_comment(line) do
    case Regex.run(~r/^(.*?)(?:^|\s)[;#].*$/, line, capture: :all_but_first) do
      [head] -> head
      _ -> line
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      s -> s
    end
  end

  defp present(_), do: nil

  defp home, do: System.user_home!() || Path.expand("~")

  @doc """
  Render a `{:aws_no_credentials, attempts}` reason as the multi-line
  explanation a user can act on.
  """
  @spec explain(term()) :: String.t()
  def explain({:aws_no_credentials, attempts}) do
    lines = Enum.map_join(attempts, "\n", fn {source, why} -> "    • #{source}: #{why}" end)

    "No AWS credentials were found. OSA looked in every place the AWS CLI does:\n" <>
      lines <>
      "\n  Fix by exporting AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY, or by running " <>
      "`aws configure` (optionally `aws configure --profile NAME` plus `export AWS_PROFILE=NAME`)."
  end

  def explain({:aws_no_region, path, profile}) do
    "No AWS region is set. Bedrock has no global endpoint, so OSA cannot guess one. " <>
      "Export AWS_REGION (e.g. `export AWS_REGION=us-east-1`), or add `region = …` to the " <>
      "[#{if profile == "default", do: "default", else: "profile #{profile}"}] section of #{path}."
  end

  def explain(other), do: inspect(other)
end
