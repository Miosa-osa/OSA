defmodule OptimalSystemAgent.Security.JsSecretsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.JsSecrets

  @aws_example "AKIAIOSFODNN7EXAMPLE"

  @jwt "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." <>
         "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ." <>
         "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

  test "AKIA key extracted with :high" do
    js = ~s[const id = "#{@aws_example}";]

    assert {:ok, hits} = JsSecrets.extract(js)
    hit = Enum.find(hits, &(&1.kind == :aws_key))
    assert hit
    assert hit.value == @aws_example
    assert hit.confidence == :high
    assert hit.line == 1
    assert hit.path == nil
  end

  test "JWT extracted" do
    js = ~s[const session = "#{@jwt}";]

    assert {:ok, hits} = JsSecrets.extract(js)
    hit = Enum.find(hits, &(&1.kind == :jwt))
    assert hit
    assert hit.value == @jwt
  end

  test ~s[fetch("https://api.internal.corp/v1") -> :internal_url] do
    js = ~s[fetch("https://api.internal.corp/v1")]

    assert {:ok, hits} = JsSecrets.extract(js)
    hit = Enum.find(hits, &(&1.kind == :internal_url))
    assert hit
    assert hit.value == "https://api.internal.corp/v1"
  end

  test ~s[password = "hunter2" -> :hardcoded_password] do
    js = ~s[password = "hunter2"]

    assert {:ok, hits} = JsSecrets.extract(js)
    hit = Enum.find(hits, &(&1.kind == :hardcoded_password))
    assert hit
    assert hit.value == "hunter2"
  end

  test "empty string -> {:ok, []}" do
    assert {:ok, []} = JsSecrets.extract("")
  end

  test "duplicate keys collapsed" do
    js = """
    const a = "#{@aws_example}";
    const b = "#{@aws_example}";
    """

    assert {:ok, hits} = JsSecrets.extract(js)
    aws = Enum.filter(hits, &(&1.kind == :aws_key))
    assert length(aws) == 1
    assert hd(aws).value == @aws_example
  end

  test "extract_file missing path errors" do
    assert {:error, msg} = JsSecrets.extract_file("/no/such/osa-js-secrets")
    assert is_binary(msg)
    assert msg != ""
  end

  test "extract_dir on a tmp folder with a.js and node_modules/skip.js only returns a.js hits" do
    root = Path.join(System.tmp_dir!(), "osa-jssec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.write!(Path.join(root, "a.js"), ~s[const id = "#{@aws_example}";\n])

    File.write!(
      Path.join(root, "node_modules/skip.js"),
      ~s[const id = "AKIAJUNKJUNKJUNKJUNK";\n]
    )

    try do
      assert {:ok, hits} = JsSecrets.extract_dir(root)

      assert Enum.any?(hits, fn h ->
               h.kind == :aws_key and h.value == @aws_example and
                 is_binary(h.path) and String.ends_with?(h.path, "a.js")
             end)

      refute Enum.any?(hits, fn h ->
               String.contains?(h.path || "", "node_modules") or
                 String.contains?(h.path || "", "skip.js") or
                 h.value == "AKIAJUNKJUNKJUNKJUNK"
             end)
    after
      File.rm_rf(root)
    end
  end

  test "no false positive on example.com CDN urls like https://cdn.jsdelivr.net/foo.js" do
    js = """
    fetch("https://cdn.jsdelivr.net/foo.js");
    fetch("https://example.com/app.js");
    const src = "https://cdn.jsdelivr.net/foo.js";
    """

    assert {:ok, hits} = JsSecrets.extract(js)
    refute Enum.any?(hits, &(&1.kind == :internal_url))
  end

  test "extract_dir errors when root is not a directory" do
    path = Path.join(System.tmp_dir!(), "osa-jssec-file-#{System.unique_integer([:positive])}")
    File.write!(path, "x")

    try do
      assert {:error, _} = JsSecrets.extract_dir(path)
    after
      File.rm(path)
    end
  end

  test "extract_file sets path and render redacts the value" do
    path = Path.join(System.tmp_dir!(), "osa-jssec-#{System.unique_integer([:positive])}.js")
    File.write!(path, ~s[const id = "#{@aws_example}";\n])

    try do
      assert {:ok, hits} = JsSecrets.extract_file(path)
      hit = Enum.find(hits, &(&1.kind == :aws_key))
      assert hit.path == path
      out = JsSecrets.render(hits)
      assert out =~ "aws_key"
      assert out =~ "high"
      refute out =~ @aws_example
      assert out =~ String.slice(@aws_example, 0, 12)
    after
      File.rm(path)
    end
  end
end
