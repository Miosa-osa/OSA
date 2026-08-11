defmodule OptimalSystemAgent.Auth.AwsCredentialsTest do
  @moduledoc """
  The chain's job is not only to find a credential — it is to be *specific*
  when it does not. "AWS credentials not found" is an unactionable message
  when there are four plausible places one could have come from, so most of
  these tests assert on what the failure NAMES, not merely that it failed.
  """
  # Mutates process environment; must not run beside anything else that reads it.
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Auth.AwsCredentials

  @vars ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
           AWS_REGION AWS_DEFAULT_REGION AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)

    dir = Path.join(System.tmp_dir!(), "osa-aws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      File.rm_rf(dir)
    end)

    # Point the file lookups at the sandbox unconditionally, so a developer's
    # real ~/.aws can never make these pass or fail.
    System.put_env("AWS_SHARED_CREDENTIALS_FILE", Path.join(dir, "credentials"))
    System.put_env("AWS_CONFIG_FILE", Path.join(dir, "config"))

    {:ok, dir: dir}
  end

  describe "resolve/0 — environment" do
    test "takes a complete env credential" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIAEXAMPLE1234")
      System.put_env("AWS_SECRET_ACCESS_KEY", "secret")

      assert {:ok, creds} = AwsCredentials.resolve()
      assert creds.access_key_id == "AKIAEXAMPLE1234"
      assert creds.secret_access_key == "secret"
      assert creds.session_token == nil
      assert creds.source =~ "environment"
    end

    test "carries a session token when one is exported" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIA")
      System.put_env("AWS_SECRET_ACCESS_KEY", "s")
      System.put_env("AWS_SESSION_TOKEN", "tok")

      assert {:ok, %{session_token: "tok"}} = AwsCredentials.resolve()
    end

    test "half an env credential does NOT silently fall through to the file", %{dir: dir} do
      # Falling through here would use a DIFFERENT AWS account than the one
      # the user just exported — the failure mode is silent and expensive.
      write!(dir, "credentials", """
      [default]
      aws_access_key_id = FROMFILE
      aws_secret_access_key = filesecret
      """)

      System.put_env("AWS_ACCESS_KEY_ID", "AKIA")

      assert {:ok, %{access_key_id: "FROMFILE"}} = AwsCredentials.resolve()
    end

    test "the half-credential mistake is NAMED in the failure when nothing else answers" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIA")

      assert {:error, {:aws_no_credentials, attempts} = reason} = AwsCredentials.resolve()
      assert Enum.any?(attempts, fn {_, why} -> why =~ "AWS_SECRET_ACCESS_KEY is not" end)
      assert AwsCredentials.explain(reason) =~ "AWS_SECRET_ACCESS_KEY"
    end
  end

  describe "resolve/0 — the shared credentials file" do
    test "reads the default profile", %{dir: dir} do
      write!(dir, "credentials", """
      [default]
      aws_access_key_id = AKIADEFAULT
      aws_secret_access_key = defsecret
      """)

      assert {:ok, %{access_key_id: "AKIADEFAULT", source: source}} = AwsCredentials.resolve()
      assert source =~ "profile default"
    end

    test "honours AWS_PROFILE and says where the name came from", %{dir: dir} do
      write!(dir, "credentials", """
      [default]
      aws_access_key_id = WRONG
      aws_secret_access_key = wrong

      [prod]
      aws_access_key_id = AKIAPROD
      aws_secret_access_key = prodsecret
      aws_session_token = prodtoken
      """)

      System.put_env("AWS_PROFILE", "prod")

      assert {:ok, creds} = AwsCredentials.resolve()
      assert creds.access_key_id == "AKIAPROD"
      assert creds.session_token == "prodtoken"
      assert creds.source =~ "from AWS_PROFILE"
    end

    test "a missing profile is distinguished from a missing file", %{dir: dir} do
      write!(dir, "credentials", "[default]\naws_access_key_id = A\naws_secret_access_key = B\n")
      System.put_env("AWS_PROFILE", "nope")

      assert {:error, {:aws_no_credentials, attempts}} = AwsCredentials.resolve()
      assert Enum.any?(attempts, fn {_, why} -> why =~ "no [nope] section" end)
    end

    test "a missing file says so, and names the path it looked at" do
      assert {:error, {:aws_no_credentials, attempts} = reason} = AwsCredentials.resolve()
      assert Enum.any?(attempts, fn {_, why} -> why =~ "does not exist" end)
      assert AwsCredentials.explain(reason) =~ "credentials"
    end

    test "an SSO profile is reported as unsupported, not as missing keys", %{dir: dir} do
      # The distinction matters: telling a user their keys are missing when
      # the profile was never going to contain keys sends them hunting for
      # something that does not exist.
      write!(dir, "credentials", """
      [default]
      sso_start_url = https://example.awsapps.com/start
      sso_account_id = 111122223333
      """)

      assert {:error, {:aws_no_credentials, attempts}} = AwsCredentials.resolve()

      assert Enum.any?(attempts, fn {_, why} ->
               why =~ "AWS SSO" and why =~ "export-credentials"
             end)
    end

    test "a credential_process profile is reported as unsupported", %{dir: dir} do
      write!(dir, "credentials", "[default]\ncredential_process = /usr/bin/get-creds\n")

      assert {:error, {:aws_no_credentials, attempts}} = AwsCredentials.resolve()
      assert Enum.any?(attempts, fn {_, why} -> why =~ "credential_process" end)
    end

    test "a role_arn profile is reported as unsupported", %{dir: dir} do
      write!(
        dir,
        "credentials",
        "[default]\nrole_arn = arn:aws:iam::1:role/x\nsource_profile = a\n"
      )

      assert {:error, {:aws_no_credentials, attempts}} = AwsCredentials.resolve()
      assert Enum.any?(attempts, fn {_, why} -> why =~ "assume_role" end)
    end
  end

  describe "the INI reader" do
    test "a '#' inside a secret is not treated as a comment", %{dir: dir} do
      # Truncating a secret at a '#' presents as SignatureDoesNotMatch, which
      # sends the user looking for a clock problem instead of a parser bug.
      write!(
        dir,
        "credentials",
        "[default]\naws_access_key_id = A\naws_secret_access_key = se#cret\n"
      )

      assert {:ok, %{secret_access_key: "se#cret"}} = AwsCredentials.resolve()
    end

    test "a trailing comment after whitespace IS stripped", %{dir: dir} do
      write!(
        dir,
        "credentials",
        "[default]\naws_access_key_id = A ; the key\naws_secret_access_key = B\n"
      )

      assert {:ok, %{access_key_id: "A"}} = AwsCredentials.resolve()
    end

    test "keys are case-insensitive and values are trimmed", %{dir: dir} do
      write!(
        dir,
        "credentials",
        "[default]\nAWS_ACCESS_KEY_ID =   A   \nAws_Secret_Access_Key = B\n"
      )

      assert {:ok, %{access_key_id: "A", secret_access_key: "B"}} = AwsCredentials.resolve()
    end
  end

  describe "region/0" do
    test "prefers AWS_REGION" do
      System.put_env("AWS_REGION", "eu-central-1")
      System.put_env("AWS_DEFAULT_REGION", "us-east-1")

      assert {:ok, "eu-central-1"} = AwsCredentials.region()
    end

    test "falls back to AWS_DEFAULT_REGION" do
      System.put_env("AWS_DEFAULT_REGION", "ap-southeast-2")
      assert {:ok, "ap-southeast-2"} = AwsCredentials.region()
    end

    test "reads the default profile from ~/.aws/config", %{dir: dir} do
      write!(dir, "config", "[default]\nregion = us-west-2\n")
      assert {:ok, "us-west-2"} = AwsCredentials.region()
    end

    test "knows the config file spells a named profile '[profile NAME]'", %{dir: dir} do
      # `~/.aws/config` prefixes non-default profiles and `~/.aws/credentials`
      # does not. Getting this wrong is why a region set in the config file
      # appears to be ignored.
      write!(dir, "config", "[profile prod]\nregion = sa-east-1\n")
      System.put_env("AWS_PROFILE", "prod")

      assert {:ok, "sa-east-1"} = AwsCredentials.region()
    end

    test "no region anywhere is a hard failure, not a guessed us-east-1" do
      assert {:error, {:aws_no_region, _path, "default"}} = AwsCredentials.region()
    end

    test "the no-region explanation names both fixes" do
      {:error, reason} = AwsCredentials.region()
      explanation = AwsCredentials.explain(reason)

      assert explanation =~ "AWS_REGION"
      assert explanation =~ "region ="
      assert explanation =~ "no global endpoint"
    end
  end

  describe "describe/0" do
    test "shows the source and only the last four characters of the key id" do
      System.put_env("AWS_ACCESS_KEY_ID", "AKIASECRETLOOKING9999")
      System.put_env("AWS_SECRET_ACCESS_KEY", "s")

      described = AwsCredentials.describe()

      assert described =~ "environment"
      assert described =~ "…9999"
      refute described =~ "AKIASECRETLOOKING"
    end

    test "says so plainly when there is nothing" do
      assert AwsCredentials.describe() == "no credential found"
    end
  end

  defp write!(dir, name, content), do: File.write!(Path.join(dir, name), content)
end
