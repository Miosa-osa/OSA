defmodule OptimalSystemAgent.Auth.AwsSigV4Test do
  @moduledoc """
  SigV4 is a function with exactly one correct output and no useful partial
  credit: a signature is either byte-identical to what AWS computes or it is a
  401 that says nothing about which of the six canonical lines was wrong. So
  these tests pin the canonical pieces individually, and the end-to-end
  signature against AWS's own published `aws-sig-v4-test-suite` vector, rather
  than asserting "a header was produced".
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Auth.AwsSigV4

  # The credential and timestamp from AWS's published test suite. Not a real
  # key — it is the fixture AWS documents its own expected signatures against,
  # which is what makes the assertion below meaningful rather than circular.
  @creds %{
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    session_token: nil
  }
  @at ~U[2015-08-30 12:36:00Z]

  describe "canonical path encoding" do
    test "percent-encodes a colon, which a Bedrock model id always contains" do
      assert AwsSigV4.canonical_path("/model/anthropic.claude-sonnet-4-5-20250929-v1:0/converse") ==
               "/model/anthropic.claude-sonnet-4-5-20250929-v1%3A0/converse"
    end

    test "leaves the unreserved set alone" do
      assert AwsSigV4.canonical_path("/a-b_c.d~e") == "/a-b_c.d~e"
    end

    test "does not encode the separators between segments" do
      assert AwsSigV4.canonical_path("/foundation-models") == "/foundation-models"
    end

    test "an absent or empty path is a single slash" do
      assert AwsSigV4.canonical_path(nil) == "/"
      assert AwsSigV4.canonical_path("") == "/"
    end

    test "uses uppercase hex, as AWS requires" do
      assert AwsSigV4.uri_encode(" ") == "%20"
      assert AwsSigV4.uri_encode("/") == "%2F"
    end
  end

  describe "canonical query" do
    test "sorts by encoded name then encoded value" do
      assert AwsSigV4.canonical_query("b=2&a=1") == "a=1&b=2"
      assert AwsSigV4.canonical_query("a=2&a=1") == "a=1&a=2"
    end

    test "a valueless parameter still carries its equals sign" do
      assert AwsSigV4.canonical_query("flag") == "flag="
    end

    test "empty and nil queries produce the empty string, not a stray separator" do
      assert AwsSigV4.canonical_query(nil) == ""
      assert AwsSigV4.canonical_query("") == ""
    end
  end

  describe "sign/6" do
    test "reproduces the AWS test-suite signature for get-vanilla" do
      # `aws-sig-v4-test-suite/get-vanilla`: GET https://example.amazonaws.com/
      # with only the Host and X-Amz-Date headers, empty body, service
      # `service`, region `us-east-1`.
      headers =
        AwsSigV4.sign("GET", "https://example.amazonaws.com/", [], "", @creds,
          region: "us-east-1",
          service: "service",
          now: @at
        )

      auth = header(headers, "authorization")

      assert auth ==
               "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " <>
                 "SignedHeaders=host;x-amz-date, " <>
                 "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
    end

    test "adds host and x-amz-date itself, and keeps them out of the caller's hands" do
      headers =
        AwsSigV4.sign(
          "GET",
          "https://example.amazonaws.com/",
          [{"host", "wrong.example"}],
          "",
          @creds,
          region: "us-east-1",
          service: "service",
          now: @at
        )

      # A header that is SIGNED and a header that is SENT must be the same
      # string, so a caller-supplied host is replaced rather than duplicated —
      # two `host` headers is a signature mismatch with no diagnostic.
      assert Enum.count(headers, fn {k, _} -> k == "host" end) == 1
      assert header(headers, "host") == "example.amazonaws.com"
      assert header(headers, "x-amz-date") == "20150830T123600Z"
    end

    test "a session token is both sent and signed" do
      creds = Map.put(@creds, :session_token, "FQoGZXIvYXdzEXAMPLE")

      headers =
        AwsSigV4.sign("GET", "https://example.amazonaws.com/", [], "", creds,
          region: "us-east-1",
          service: "service",
          now: @at
        )

      assert header(headers, "x-amz-security-token") == "FQoGZXIvYXdzEXAMPLE"

      # Signing it but not sending it (or the reverse) is the classic way
      # temporary credentials "work locally and fail in CI".
      assert header(headers, "authorization") =~ "x-amz-security-token"
    end

    test "the body is part of the signature" do
      sign = fn body ->
        AwsSigV4.sign("POST", "https://example.amazonaws.com/", [], body, @creds,
          region: "us-east-1",
          service: "service",
          now: @at
        )
        |> header("authorization")
      end

      refute sign.(~s({"a":1})) == sign.(~s({"a":2}))
    end

    test "the region and service are part of the signature" do
      sign = fn opts ->
        AwsSigV4.sign("GET", "https://example.amazonaws.com/", [], "", @creds, opts)
        |> header("authorization")
      end

      base = [region: "us-east-1", service: "bedrock", now: @at]

      refute sign.(base) == sign.(Keyword.put(base, :region, "eu-central-1"))
      refute sign.(base) == sign.(Keyword.put(base, :service, "bedrock-runtime"))
    end

    test "the secret never appears in any produced header" do
      headers =
        AwsSigV4.sign("GET", "https://example.amazonaws.com/", [], "", @creds,
          region: "us-east-1",
          service: "service",
          now: @at
        )

      serialized = Enum.map_join(headers, "\n", fn {k, v} -> "#{k}: #{v}" end)

      refute serialized =~ @creds.secret_access_key
      # The key ID is expected — AWS puts it on the wire itself.
      assert serialized =~ "AKIDEXAMPLE"
    end

    test "a non-default port is included in the host header" do
      headers =
        AwsSigV4.sign("GET", "https://example.amazonaws.com:8443/", [], "", @creds,
          region: "us-east-1",
          service: "service",
          now: @at
        )

      assert header(headers, "host") == "example.amazonaws.com:8443"
    end
  end

  describe "amz_datetime/1" do
    test "is zero-padded basic-format UTC" do
      assert AwsSigV4.amz_datetime(~U[2026-01-02 03:04:05Z]) == "20260102T030405Z"
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end
end
