defmodule OptimalSystemAgent.Security.TrafficIngestTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.TrafficIngest

  test "HAR entries become endpoint findings" do
    har = """
    {"log":{"entries":[
      {"request":{"method":"GET","url":"https://app.example/api/users"},
       "response":{"status":200}},
      {"request":{"method":"POST","url":"https://app.example/api/users"},
       "response":{"status":201}}
    ]}}
    """

    assert {:ok, notes} = TrafficIngest.har(har)
    assert length(notes) == 2
    assert Enum.any?(notes, &("GET" in hd(&1.endpoints).methods))
    assert hd(notes).source == "har"
  end

  test "rejects a non-HAR blob" do
    assert {:error, _} = TrafficIngest.har("{}")
  end

  test "OpenAPI paths become high-confidence endpoint notes" do
    spec = """
    {"openapi":"3.0.0","servers":[{"url":"https://api.example"}],
     "paths":{
       "/pets":{"get":{},"post":{}},
       "/pets/{id}":{"get":{},"delete":{}}
     }}
    """

    assert {:ok, notes} = TrafficIngest.openapi(spec)
    assert length(notes) == 2
    pets = Enum.find(notes, &(&1.metadata["spec_path"] == "/pets"))
    assert "GET" in hd(pets.endpoints).methods
    assert "POST" in hd(pets.endpoints).methods
    assert pets.target == "https://api.example/pets"
    assert pets.confidence == :high
  end
end
