defmodule OptimalSystemAgent.Security.ReconIngestTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.ReconIngest

  test "empty payload is an empty list, not an error" do
    assert {:ok, []} = ReconIngest.ingest(:nmap, :xml, "")
  end

  test "unknown tool is an error" do
    assert {:error, _} = ReconIngest.ingest(:nope, :json, "{}")
  end

  test "nmap xml extracts an open ssh port" do
    xml = """
    <nmaprun>
      <host><status state="up"/><address addr="10.0.0.5" addrtype="ipv4"/>
        <ports>
          <port protocol="tcp" portid="22"><state state="open"/><service name="ssh" product="OpenSSH" version="8.9"/></port>
        </ports>
      </host>
    </nmaprun>
    """

    assert {:ok, [note]} = ReconIngest.ingest(:nmap, :xml, xml)
    assert note.category == :finding
    assert note.target == "10.0.0.5"
    assert hd(note.services).port == 22
    assert hd(note.services).product =~ "OpenSSH"
  end

  test "httpx jsonl becomes a finding with technologies" do
    line =
      ~s({"url":"https://a.example/","status_code":200,"title":"Home","tech":["nginx"],"host":"a.example","port":443})

    assert {:ok, [note]} = ReconIngest.ingest("httpx", "jsonl", line)
    assert note.target =~ "a.example"
    assert hd(note.technologies).name == "nginx"
  end

  test "subfinder text is one finding per domain" do
    assert {:ok, notes} = ReconIngest.ingest(:subfinder, :text, "a.example.com\nb.example.com\n")
    assert Enum.map(notes, & &1.target) == ["a.example.com", "b.example.com"]
  end

  test "nuclei without a CVE still has weaknesses so the note schema is satisfied" do
    line =
      ~s({"template-id":"cve-test","info":{"name":"n","severity":"high"},"matched-at":"https://t/x"})

    assert {:ok, [note]} = ReconIngest.ingest(:nuclei, :jsonl, line)
    assert note.category == :vulnerability
    assert note.weaknesses == [%{id: "cve-test"}]
    assert note.confidence == :high
    assert is_nil(note.cve)
  end

  test "malformed jsonl lines are skipped, not fatal" do
    payload = "not-json\n{\"host\":\"1.2.3.4\",\"port\":80,\"protocol\":\"tcp\"}\n"
    assert {:ok, [note]} = ReconIngest.ingest(:naabu, :jsonl, payload)
    assert note.target == "1.2.3.4"
    assert hd(note.services).port == 80
  end

  test "map form used by security_intel" do
    assert {:ok, []} =
             ReconIngest.ingest(%{"tool" => "httpx", "format" => "jsonl", "payload" => ""})
  end
end
