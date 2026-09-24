# The operator hit this: the checkout said one config key, the release that was
# actually running read another. The right move is to look at what is RUNNING
# once, then act; not to trust the checkout, and not to re-verify five times.
%{
  id: "stale-release-key",
  title: "Which config key does the installed release read?",
  category: "verify",
  failure_mode: "stale checkout vs installed release: verify once at the source of truth, then act",
  prompt: """
  Production runs the installed release in _build/prod/rel/acme, not this checkout (the checkout is \
  ahead of it). Which key in config/settings.json does the installed release read for the outbound \
  HTTP timeout? Set that key to 45000 in config/settings.json and tell me the key name.
  """,
  setup: [
    {:write, "_build/prod/rel/acme/releases/start_erl.data", "15 2.2.0\n"},
    {:write, "_build/prod/rel/acme/releases/2.2.0/sys.config", "[{acme, []}].\n"},
    {:write, "_build/prod/rel/acme/lib/acme-2.2.0/src/acme/http/client.ex", """
    defmodule Acme.Http.Client do
      @moduledoc "Outbound HTTP. Reads its timeout from config/settings.json."

      def timeout(settings), do: Map.fetch!(settings, "http_timeout")
    end
    """}
  ],
  check: [
    {:json_equals, "config/settings.json", ["http_timeout"], 45000},
    {:json_equals, "config/settings.json", ["request_timeout_ms"], 30000},
    {:json_unchanged_except, "config/settings.json", [["http_timeout"]]},
    {:answer_matches, "http_timeout"}
  ],
  reference: [
    [{"file_read", %{"path" => "$WORKDIR/_build/prod/rel/acme/lib/acme-2.2.0/src/acme/http/client.ex"}},
     {"file_read", %{"path" => "$WORKDIR/config/settings.json"}}],
    [{"file_edit", %{"path" => "$WORKDIR/config/settings.json",
                     "old_string" => "\"http_timeout\": 30000",
                     "new_string" => "\"http_timeout\": 45000"}}],
    {:answer, "The installed release reads `http_timeout`; it is now 45000."}
  ]
}
