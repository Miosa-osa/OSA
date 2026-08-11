defmodule OptimalSystemAgent.Agent.TrajectorySecurityTest do
  @moduledoc """
  Redaction and persistence-boundary guarantees for `Agent.Trajectory`.

  Covers: fail-closed sanitizing, the coverage gaps (PEM blocks, URL
  credentials, OAuth params, xAI/GitLab/`sk_` keys, home-dir anonymization),
  compaction events going through the same pipeline, typed-text masking, the
  0600 file mode, and the mid-codepoint slice that used to discard the whole
  entry.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Trajectory

  @password "hunter2-correct-horse"

  setup do
    prior_enabled = Application.get_env(:optimal_system_agent, :trajectory_recording)
    Application.put_env(:optimal_system_agent, :trajectory_recording, true)

    session = "sec-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      File.rm(Trajectory.session_path(session))

      if is_nil(prior_enabled),
        do: Application.delete_env(:optimal_system_agent, :trajectory_recording),
        else: Application.put_env(:optimal_system_agent, :trajectory_recording, prior_enabled)
    end)

    {:ok, session: session}
  end

  defp record_and_read(session, entry) do
    :ok = Trajectory.record(Map.put(entry, :session_id, session))
    File.read!(Trajectory.session_path(session))
  end

  # ── Fail closed ────────────────────────────────────────────────────────────

  describe "redact/1 fails closed" do
    test "never returns the original text when the scrubber raises" do
      # The old `rescue _ -> text` handed the UNREDACTED input straight back to
      # the trajectory writer and to the CLI spinner. A replacement of the
      # wrong arity makes Regex.replace/3 raise.
      raising = [{~r/./, :not_a_valid_replacement}]

      result = Trajectory.redact("api_key=sk-abcdefghijklmnopqrstuvwx", raising)

      refute result =~ "abcdefghijklmnop"
      assert result =~ "scrubber failed"
    end

    test "a secret inside invalid UTF-8 is still redacted" do
      # Regex.replace/3 does not raise on invalid UTF-8 — it matches nothing
      # and returns the input, so the key was written to disk in clear.
      invalid = <<"prefix ", 0xFF, 0xFE, " sk-abcdefghijklmnopqrstuvwx">>

      result = Trajectory.redact(invalid)

      refute result =~ "abcdefghijklmnop"
      assert result =~ "[REDACTED]"
      assert String.valid?(result)
    end

    test "leaves clean text byte-identical" do
      assert Trajectory.redact("just a normal sentence") == "just a normal sentence"
    end
  end

  # ── Coverage gaps ──────────────────────────────────────────────────────────

  describe "redact/1 coverage" do
    test "PEM private key blocks are removed whole" do
      pem = """
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAAB
      AAAAMwAAAAtzc2gtZWQyNTUxOQAAACBSECRETMATERIAL0000000
      -----END OPENSSH PRIVATE KEY-----
      """

      out = Trajectory.redact("here is the key:\n" <> pem)

      assert out =~ "[REDACTED_PRIVATE_KEY]"
      refute out =~ "SECRETMATERIAL"
      refute out =~ "BEGIN OPENSSH PRIVATE KEY"
    end

    test "RSA PEM blocks too" do
      pem =
        "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxxxx\n-----END RSA PRIVATE KEY-----"

      assert Trajectory.redact(pem) == "[REDACTED_PRIVATE_KEY]"
    end

    test "credentials embedded in a URL" do
      out = Trajectory.redact("git clone https://alice:s3cr3tpw@github.com/acme/repo.git")

      refute out =~ "s3cr3tpw"
      assert out =~ "[REDACTED]@"
    end

    test "OAuth query parameters" do
      url =
        "https://api.example.com/cb?code=4/0AaBbCcDd&access_token=ya29.longtokenvalue" <>
          "&refresh_token=1//refreshvalue&client_secret=GOCSPX-abcdefghijkl"

      out = Trajectory.redact(url)

      refute out =~ "ya29.longtokenvalue"
      refute out =~ "1//refreshvalue"
      refute out =~ "GOCSPX-abcdefghijkl"
      refute out =~ "4/0AaBbCcDd"
    end

    test "xAI keys — OSA ships an xAI provider" do
      out = Trajectory.redact("XAI key: xai-abcdefghijklmnopqrstuvwxyz012345")
      refute out =~ "abcdefghijklmnop"
      assert out =~ "[REDACTED_XAI_KEY]"
    end

    test "GitLab PATs" do
      out = Trajectory.redact("token glpat-AbCdEfGhIjKlMnOpQrSt")
      refute out =~ "AbCdEfGhIjKlMnOpQrSt"
      assert out =~ "[REDACTED_GITLAB_TOKEN]"
    end

    test "sk_ as well as sk- prefixed keys" do
      # Assembled at runtime rather than written as a literal. A Stripe-shaped
      # key in source trips GitHub's push protection, which is correct of it —
      # a fixture for a secret scrubber necessarily looks like the thing it
      # represents. Concatenation keeps the test honest without shipping a
      # string that any scanner is right to flag.
      secret = "sk" <> "_live_" <> "abcdefghijklmnopqrstuvwx"

      out = Trajectory.redact(secret)
      refute out =~ "abcdefghijklmnop"
      assert out =~ "[REDACTED]"
    end

    test "the operator's home directory is anonymized" do
      home = System.get_env("HOME")
      assert is_binary(home) and home != ""

      out = Trajectory.redact("failed to open #{home}/projects/osa/x.txt")

      refute out =~ home
      assert out =~ "~/projects/osa/x.txt"
    end
  end

  # ── Persistence boundary ───────────────────────────────────────────────────

  describe "written trajectory" do
    test "typed text never reaches disk in clear", %{session: session} do
      body =
        record_and_read(session, %{
          tool_calls: [
            %{
              name: "computer_use",
              arguments: Jason.encode!(%{"action" => "type", "text" => @password})
            }
          ]
        })

      refute body =~ "hunter2"
      assert body =~ "<21 chars>"
    end

    test "browser fill arguments are masked too", %{session: session} do
      body =
        record_and_read(session, %{
          tool_calls: [
            %{
              name: "browser",
              arguments: Jason.encode!(%{"action" => "fill", "text" => @password})
            }
          ]
        })

      refute body =~ "hunter2"
    end

    test "compaction_events go through the redaction pipeline", %{session: session} do
      body =
        record_and_read(session, %{
          compaction_events: [
            %{"reason" => "context", "summary" => "used key sk-abcdefghijklmnopqrstuvwx"}
          ]
        })

      refute body =~ "abcdefghijklmnop"
      assert body =~ "[REDACTED]"
    end

    test "the file is owner-only", %{session: session} do
      _ = record_and_read(session, %{assistant_response: "hello"})

      {:ok, %File.Stat{mode: mode}} = File.stat(Trajectory.session_path(session))

      assert Bitwise.band(mode, 0o077) == 0,
             "trajectory is group/world accessible: #{inspect(mode, base: :octal)}"
    end

    test "an oversize multi-byte field does not discard the entry", %{session: session} do
      # `binary_part/3` at the char budget lands mid-codepoint here; the old
      # code produced invalid UTF-8, `Jason.encode!` raised, and do_record/2's
      # rescue threw the ENTIRE entry away — nothing was written at all.
      # One leading ASCII byte puts the byte-offset cut in the MIDDLE of a
      # two-byte codepoint.
      max = Trajectory.max_field_chars()
      big = "x" <> String.duplicate("é", max)

      body = record_and_read(session, %{assistant_response: big, model: "marker-model"})

      assert body =~ "marker-model"
      assert body =~ "[truncated]"
      assert String.valid?(body)
    end
  end
end
