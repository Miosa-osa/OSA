defmodule OptimalSystemAgent.Providers.BatchTest do
  @moduledoc """
  Locks in the OpenAI Batch API foundation (`Providers.Batch`).

  Every test drives an INJECTED http client — no request is ever sent. The
  properties worth pinning are: submit builds correct JSONL + uploads the file
  with purpose "batch" + creates the batch with a 24h window; status parses
  each documented state; results downloads and parses the JSONL output and maps
  it back to custom_ids; and the error paths (upload fails, batch failed) return
  `{:error, _}`.

  > #### Nothing here has spoken to OpenAI {: .warning}
  >
  > There are no api.openai.com credentials in play. Every assertion is about
  > what OSA BUILDS and how it PARSES a canned response.
  """
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Providers.Batch

  # A recording http mock: captures every request into the test process mailbox
  # and replies from a scripted list (one reply per call, in order).
  defp scripted(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    test = self()

    fn request ->
      send(test, {:request, request})

      reply =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {{:error, "no scripted reply"}, []}
        end)

      reply
    end
  end

  @sample_requests [
    %{"model" => "gpt-4o", "messages" => [%{"role" => "user", "content" => "one"}]},
    %{"model" => "gpt-4o", "messages" => [%{"role" => "user", "content" => "two"}]}
  ]

  describe "submit/2" do
    test "builds JSONL, uploads with purpose batch, creates a 24h batch, returns the id" do
      http =
        scripted([
          {:ok, %{status: 200, body: %{"id" => "file_abc"}}},
          {:ok, %{status: 200, body: %{"id" => "batch_xyz", "status" => "validating"}}}
        ])

      assert {:ok, "batch_xyz"} = Batch.submit(@sample_requests, http: http, api_key: "sk-test")

      # First call: the file upload.
      assert_receive {:request, upload}
      assert upload.method == :post
      assert String.ends_with?(upload.url, "/files")
      assert {"Authorization", "Bearer sk-test"} in upload.headers
      assert upload.multipart["purpose"] == "batch"

      {filename, content_type, jsonl} = upload.multipart["file"]
      assert filename =~ ".jsonl"
      assert content_type =~ "jsonl"

      # One JSONL line per request, each wrapping the chat body under "body"
      # with an assigned custom_id and the chat-completions endpoint.
      lines = String.split(jsonl, "\n", trim: true)
      assert length(lines) == 2

      first = Jason.decode!(Enum.at(lines, 0))
      assert first["custom_id"] == "request-0"
      assert first["method"] == "POST"
      assert first["url"] == "/v1/chat/completions"
      assert first["body"]["model"] == "gpt-4o"
      assert first["body"]["messages"] == [%{"role" => "user", "content" => "one"}]

      assert Jason.decode!(Enum.at(lines, 1))["custom_id"] == "request-1"

      # Second call: the batch create.
      assert_receive {:request, create}
      assert create.method == :post
      assert String.ends_with?(create.url, "/batches")
      assert create.json["input_file_id"] == "file_abc"
      assert create.json["endpoint"] == "/v1/chat/completions"
      assert create.json["completion_window"] == "24h"
    end

    test "honors a caller-supplied custom_id" do
      http =
        scripted([
          {:ok, %{status: 200, body: %{"id" => "file_abc"}}},
          {:ok, %{status: 200, body: %{"id" => "batch_xyz"}}}
        ])

      reqs = [%{"custom_id" => "my-id", "model" => "gpt-4o", "messages" => []}]
      assert {:ok, "batch_xyz"} = Batch.submit(reqs, http: http, api_key: "sk-test")

      assert_receive {:request, upload}
      {_f, _c, jsonl} = upload.multipart["file"]
      line = jsonl |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
      assert line["custom_id"] == "my-id"
      # custom_id is not duplicated into the request body.
      refute Map.has_key?(line["body"], "custom_id")
    end

    test "returns {:error, _} when the file upload fails" do
      http =
        scripted([
          {:ok, %{status: 401, body: %{"error" => %{"message" => "bad key"}}}}
        ])

      assert {:error, reason} = Batch.submit(@sample_requests, http: http, api_key: "sk-test")
      assert reason =~ "upload failed"
      assert reason =~ "bad key"
    end

    test "returns {:error, _} when the batch create fails" do
      http =
        scripted([
          {:ok, %{status: 200, body: %{"id" => "file_abc"}}},
          {:ok, %{status: 400, body: %{"error" => %{"message" => "bad window"}}}}
        ])

      assert {:error, reason} = Batch.submit(@sample_requests, http: http, api_key: "sk-test")
      assert reason =~ "create failed"
    end

    test "rejects a non-openai provider without touching http" do
      assert {:error, reason} =
               Batch.submit(@sample_requests, provider: :groq, api_key: "x", http: fn _ -> :boom end)

      assert reason =~ ":openai"
    end
  end

  describe "status/2" do
    for state <- ~w(validating in_progress finalizing completed failed expired cancelling cancelled) do
      test "parses the #{state} state" do
        state = unquote(state)

        http =
          scripted([
            {:ok, %{status: 200, body: %{"id" => "batch_1", "status" => state}}}
          ])

        assert {:ok, parsed} = Batch.status("batch_1", http: http, api_key: "sk-test")
        assert parsed.status == state

        assert_receive {:request, req}
        assert req.method == :get
        assert String.ends_with?(req.url, "/batches/batch_1")
      end
    end

    test "surfaces output_file_id and error_file_id" do
      http =
        scripted([
          {:ok,
           %{
             status: 200,
             body: %{
               "id" => "batch_1",
               "status" => "completed",
               "output_file_id" => "file_out",
               "error_file_id" => "file_err"
             }
           }}
        ])

      assert {:ok, parsed} = Batch.status("batch_1", http: http, api_key: "sk-test")
      assert parsed.output_file_id == "file_out"
      assert parsed.error_file_id == "file_err"
    end

    test "returns {:error, _} on an HTTP failure" do
      http = scripted([{:ok, %{status: 404, body: %{"error" => %{"message" => "no such batch"}}}}])
      assert {:error, reason} = Batch.status("nope", http: http, api_key: "sk-test")
      assert reason =~ "status fetch failed"
    end
  end

  describe "results/2" do
    test "downloads the output file and maps rows back to custom_ids" do
      output_jsonl =
        [
          %{
            "custom_id" => "request-0",
            "response" => %{
              "status_code" => 200,
              "body" => %{"choices" => [%{"message" => %{"content" => "answer one"}}]}
            },
            "error" => nil
          },
          %{
            "custom_id" => "request-1",
            "response" => %{
              "status_code" => 200,
              "body" => %{"choices" => [%{"message" => %{"content" => "answer two"}}]}
            },
            "error" => nil
          }
        ]
        |> Enum.map(&Jason.encode!/1)
        |> Enum.join("\n")

      http =
        scripted([
          {:ok,
           %{
             status: 200,
             body: %{"id" => "batch_1", "status" => "completed", "output_file_id" => "file_out"}
           }},
          {:ok, %{status: 200, body: output_jsonl}}
        ])

      assert {:ok, rows} = Batch.results("batch_1", http: http, api_key: "sk-test")
      assert length(rows) == 2

      by_id = Map.new(rows, &{&1.custom_id, &1})
      assert by_id["request-0"].response["choices"] |> hd() |> get_in(["message", "content"]) ==
               "answer one"

      assert by_id["request-1"].response["choices"] |> hd() |> get_in(["message", "content"]) ==
               "answer two"

      assert by_id["request-0"].error == nil

      # The second http call was the file content download.
      assert_receive {:request, _batch_get}
      assert_receive {:request, content_get}
      assert content_get.method == :get
      assert String.ends_with?(content_get.url, "/files/file_out/content")
    end

    test "skips a malformed JSONL line rather than failing the whole download" do
      output = ~s({"custom_id":"request-0","response":{"body":{"ok":true}}}\nNOT JSON\n)

      http =
        scripted([
          {:ok,
           %{
             status: 200,
             body: %{"id" => "b", "status" => "completed", "output_file_id" => "file_out"}
           }},
          {:ok, %{status: 200, body: output}}
        ])

      assert {:ok, [row]} = Batch.results("b", http: http, api_key: "sk-test")
      assert row.custom_id == "request-0"
      assert row.response == %{"ok" => true}
    end

    test "returns {:error, {:not_completed, status}} when the batch is still running" do
      http =
        scripted([{:ok, %{status: 200, body: %{"id" => "b", "status" => "in_progress"}}}])

      assert {:error, {:not_completed, "in_progress"}} =
               Batch.results("b", http: http, api_key: "sk-test")
    end

    test "returns {:error, {:batch_failed, status}} for a terminal failure" do
      http = scripted([{:ok, %{status: 200, body: %{"id" => "b", "status" => "failed"}}}])

      assert {:error, {:batch_failed, "failed"}} =
               Batch.results("b", http: http, api_key: "sk-test")
    end

    test "returns {:error, _} when the output download fails" do
      http =
        scripted([
          {:ok,
           %{
             status: 200,
             body: %{"id" => "b", "status" => "completed", "output_file_id" => "file_out"}
           }},
          {:ok, %{status: 500, body: %{"error" => %{"message" => "storage down"}}}}
        ])

      assert {:error, reason} = Batch.results("b", http: http, api_key: "sk-test")
      assert reason =~ "download failed"
    end
  end

  describe "build_jsonl/1 (unit)" do
    test "produces one line per request wrapping the body" do
      jsonl = Batch.build_jsonl(@sample_requests)
      assert jsonl |> String.split("\n") |> length() == 2
    end
  end
end
