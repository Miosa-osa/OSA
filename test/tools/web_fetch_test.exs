defmodule OptimalSystemAgent.Tools.Builtins.WebFetchTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.WebFetch.{Constants, Handler, Prompt, Tool, UI}
  alias OptimalSystemAgent.Tools.UseContext

  @ctx %UseContext{session_id: "test-session"}

  # Point `Handler`'s SSRF host lookup at a fixed answer instead of live DNS.
  # `:web_fetch_resolver` is read by nothing else in the tree (this is the only
  # test module that touches `WebFetch.Handler`), and it is cleared on exit, so
  # `async: true` stays safe.
  defp stub_resolver(result) do
    Application.put_env(:optimal_system_agent, :web_fetch_resolver, fn _host, _family ->
      result
    end)

    on_exit(fn -> Application.delete_env(:optimal_system_agent, :web_fetch_resolver) end)
  end

  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  describe "Constants" do
    test "tool_name/0 returns web_fetch" do
      assert Constants.tool_name() == "web_fetch"
    end

    test "default_max_length/0 is a positive integer" do
      assert is_integer(Constants.default_max_length())
      assert Constants.default_max_length() > 0
    end

    test "max_redirects/0 is a positive integer" do
      assert is_integer(Constants.max_redirects())
      assert Constants.max_redirects() > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Tool declarations
  # ---------------------------------------------------------------------------

  describe "Tool declarations" do
    test "name/0 returns web_fetch" do
      assert Tool.name() == "web_fetch"
    end

    test "should_defer?/0 is false" do
      refute Tool.should_defer?()
    end

    test "always_load?/0 is true" do
      assert Tool.always_load?()
    end

    test "concurrency_safe?/2 is true" do
      assert Tool.concurrency_safe?(%{}, @ctx)
    end

    test "read_only?/2 is true" do
      assert Tool.read_only?(%{}, @ctx)
    end

    test "destructive?/2 is false" do
      refute Tool.destructive?(%{}, @ctx)
    end

    test "open_world?/2 is true" do
      assert Tool.open_world?(%{}, @ctx)
    end

    test "max_result_size_chars/0 is 50_000" do
      assert Tool.max_result_size_chars() == 50_000
    end

    test "safety/0 is :read_only" do
      assert Tool.safety() == :read_only
    end

    test "parameters/0 requires url" do
      params = Tool.parameters()
      assert params["required"] == ["url"]
      assert Map.has_key?(params["properties"], "url")
      assert Map.has_key?(params["properties"], "max_length")
    end

    test "to_classifier_input/1 extracts url" do
      assert Tool.to_classifier_input(%{"url" => "https://example.com"}) ==
               %{url: "https://example.com"}
    end

    test "to_classifier_input/1 returns empty string for missing url" do
      assert Tool.to_classifier_input(%{}) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # Prompt
  # ---------------------------------------------------------------------------

  describe "Prompt.render/1" do
    test "returns a non-empty string" do
      prompt = Prompt.render([])
      assert is_binary(prompt)
      assert String.length(prompt) > 0
    end

    test "mentions HTTPS requirement" do
      assert Prompt.render([]) =~ "HTTPS"
    end

    test "mentions web_search for discovery" do
      assert Prompt.render([]) =~ "web_search"
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.validate/2
  # ---------------------------------------------------------------------------

  describe "Handler.validate/2" do
    test "accepts a valid url string" do
      assert {:ok, %{"url" => "https://example.com"}} =
               Handler.validate(%{"url" => "https://example.com"}, @ctx)
    end

    test "rejects non-string url" do
      assert {:error, "url must be a string", -32_602} =
               Handler.validate(%{"url" => 42}, @ctx)
    end

    test "rejects missing url" do
      assert {:error, "Missing required parameter: url", -32_602} =
               Handler.validate(%{}, @ctx)
    end

    test "passes through additional params" do
      input = %{"url" => "https://example.com", "max_length" => 500}
      assert {:ok, ^input} = Handler.validate(input, @ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.check_permissions/2 — URL validation
  # ---------------------------------------------------------------------------

  describe "Handler.check_permissions/2" do
    test "allows a valid https URL" do
      # Stub the resolver to a public address. Without this the assertion
      # depends on a live DNS lookup for example.com, which under a full-suite
      # run intermittently returned nothing and turned this into
      # {:deny, "Cannot resolve host: example.com"} — a resolver failure
      # reported as a permission decision. The guard being tested (public
      # address => allow) is exercised exactly as before.
      stub_resolver({:ok, [{93, 184, 216, 34}]})

      input = %{"url" => "https://example.com"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end

    test "a host that resolves to a private address is still denied" do
      # The stub must not be able to wave through an SSRF target: same code
      # path, private answer, still denied (DNS-rebinding protection).
      stub_resolver({:ok, [{10, 0, 0, 1}]})

      assert {:deny, "Access denied: " <> _} =
               Handler.check_permissions(%{"url" => "https://internal.example"}, @ctx)
    end

    test "allows localhost http URL" do
      input = %{"url" => "http://localhost:4000/api"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end

    test "allows 127.0.0.1 http URL" do
      input = %{"url" => "http://127.0.0.1:8080/health"}
      assert {:allow, ^input} = Handler.check_permissions(input, @ctx)
    end

    test "denies plain http URL" do
      assert {:deny, "Access denied: " <> _reason} =
               Handler.check_permissions(%{"url" => "http://example.com"}, @ctx)
    end

    test "denies ftp:// scheme" do
      assert {:deny, "Access denied: " <> _reason} =
               Handler.check_permissions(%{"url" => "ftp://example.com/file"}, @ctx)
    end

    test "denies file:// scheme" do
      assert {:deny, "Access denied: " <> _reason} =
               Handler.check_permissions(%{"url" => "file:///etc/passwd"}, @ctx)
    end

    test "deny reason starts with 'Access denied:'" do
      {:deny, reason} = Handler.check_permissions(%{"url" => "http://example.com"}, @ctx)
      assert String.starts_with?(reason, "Access denied:")
    end
  end

  # ---------------------------------------------------------------------------
  # UI.render/3
  # ---------------------------------------------------------------------------

  describe "UI.render/3" do
    test ":tool_use returns kind web_fetch with url" do
      result = UI.render(:tool_use, %{"url" => "https://example.com"}, [])
      assert result.kind == "web_fetch"
      assert result.url == "https://example.com"
    end

    test ":tool_result returns kind web_fetch_result with bytes" do
      result = UI.render(:tool_result, "some content", [])
      assert result.kind == "web_fetch_result"
      assert is_integer(result.bytes)
    end

    test ":rejected returns kind web_fetch_rejected" do
      assert %{kind: "web_fetch_rejected"} = UI.render(:rejected, %{}, [])
    end

    test ":error returns kind web_fetch_error with message" do
      result = UI.render(:error, "something went wrong", [])
      assert result.kind == "web_fetch_error"
      assert result.message == "something went wrong"
    end

    test "unknown stage returns nil" do
      assert nil == UI.render(:unknown_stage, %{}, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Handler.execute/2 — against a real local HTTP server.
  #
  # Regression cover for the "Received 78B" defect: Req normalises response
  # headers to a MAP of name => LIST of values, so `extract_content_type/1`
  # handed a LIST to `String.contains?/2`, which has no matching clause. EVERY
  # 2xx fetch raised, and the 78-byte
  # `"Error: Tool execution error: no function clause matching in String.contains?/2"`
  # was rendered as a successful "Received 78B" cell while the model treated it
  # as documentation.
  # ---------------------------------------------------------------------------

  defmodule StubServer do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/ok" do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(
        200,
        "<html><head><style>b{}</style></head><body><h1>Real Page</h1>" <>
          "<p>This paragraph is long enough to count as genuine page content.</p></body></html>"
      )
    end

    get "/ua" do
      ua = conn |> get_req_header("user-agent") |> List.first() || ""

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, "user-agent seen by the server was: " <> ua)
    end

    get "/empty" do
      conn |> put_resp_content_type("text/html") |> send_resp(200, "")
    end

    get "/shell" do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<html><body><div id=\"root\">Loading…</div></body></html>")
    end

    get "/challenge" do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(
        200,
        "<html><body><h1>Just a moment...</h1><p>Checking your browser before " <>
          "you access this site. Please wait while we verify your request.</p></body></html>"
      )
    end

    get "/forbidden" do
      conn |> put_resp_content_type("text/html") |> send_resp(403, "<html>nope</html>")
    end

    get "/ratelimited" do
      conn |> send_resp(429, "slow down")
    end

    get "/redirect" do
      # Relative Location — must be resolved against the request URL.
      conn |> put_resp_header("location", "/ok") |> send_resp(302, "")
    end

    match _ do
      send_resp(conn, 404, "missing")
    end
  end

  # setup_all (module level), not a per-test setup: these tests run
  # concurrently and would otherwise race for the same listener port
  # (:eaddrinuse). One stub server serves the whole module.
  setup_all do
    port = 10_131
    {:ok, pid} = Bandit.start_link(plug: StubServer, port: port, ip: {127, 0, 0, 1})
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    {:ok, base: "http://127.0.0.1:#{port}"}
  end

  describe "Handler.execute/2 against a live server" do
    test "a real page is returned with a url / HTTP status / content-type envelope", %{base: base} do
      assert {:ok, body} = Handler.execute(%{"url" => base <> "/ok"}, @ctx)
      [url_line, http_line, sep | _] = String.split(body, "\n")
      assert url_line == base <> "/ok"
      assert String.starts_with?(http_line, "HTTP 200 text/html")
      assert sep == "---"
      assert body =~ "Real Page"
      # scripts/styles stripped, tags gone
      refute body =~ "<h1>"
    end

    test "a browser-shaped User-Agent is actually sent", %{base: base} do
      assert {:ok, body} = Handler.execute(%{"url" => base <> "/ua"}, @ctx)
      assert body =~ "Mozilla/5.0"
      assert body =~ "OSAAgent"
    end

    test "a relative redirect is resolved and followed", %{base: base} do
      assert {:ok, body} = Handler.execute(%{"url" => base <> "/redirect"}, @ctx)
      # The FINAL url (post-redirect) is what the envelope reports.
      assert String.starts_with?(body, base <> "/ok\n")
      assert body =~ "Real Page"
    end

    test "a 403 is a model-visible FAILURE naming the status, not content", %{base: base} do
      assert {:error, reason} = Handler.execute(%{"url" => base <> "/forbidden"}, @ctx)
      assert reason =~ "403"
      assert reason =~ "No content was retrieved"
    end

    test "a 429 is a model-visible FAILURE naming the status", %{base: base} do
      assert {:error, reason} = Handler.execute(%{"url" => base <> "/ratelimited"}, @ctx)
      assert reason =~ "429"
      assert reason =~ "rate limited"
    end

    test "a 404 is a model-visible FAILURE naming the status", %{base: base} do
      assert {:error, reason} = Handler.execute(%{"url" => base <> "/nope"}, @ctx)
      assert reason =~ "404"
    end

    test "an empty 200 body is a FAILURE, not an empty success", %{base: base} do
      assert {:error, reason} = Handler.execute(%{"url" => base <> "/empty"}, @ctx)
      assert reason =~ "EMPTY body"
    end

    test "a JS-only shell with no text is a FAILURE", %{base: base} do
      assert {:error, reason} = Handler.execute(%{"url" => base <> "/shell"}, @ctx)
      assert reason =~ "characters of text"
    end

    test "a bot-protection challenge page is a FAILURE", %{base: base} do
      assert {:error, reason} = Handler.execute(%{"url" => base <> "/challenge"}, @ctx)
      assert reason =~ "bot-protection challenge"
    end
  end

  # ---------------------------------------------------------------------------
  # Shim — flat module still compiles and delegates
  # ---------------------------------------------------------------------------

  describe "WebFetch shim" do
    test "name/0 delegates correctly" do
      assert OptimalSystemAgent.Tools.Builtins.WebFetch.name() == "web_fetch"
    end

    test "safety/0 delegates correctly" do
      assert OptimalSystemAgent.Tools.Builtins.WebFetch.safety() == :read_only
    end
  end
end
