defmodule OptimalSystemAgent.Security.SurfaceMapTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.SurfaceMap

  # ---------------------------------------------------------------------------
  # cidrs_from_whois/1
  # ---------------------------------------------------------------------------

  describe "cidrs_from_whois/1" do
    test "parses CIDR and converts exact NetRange 192.0.2.0-192.0.2.255 to /24" do
      blob = """
      OrgName:        Example Org
      OrgId:          EXAMP
      Address:        123 Documentation Drive
      CIDR:           198.51.100.0/24
      NetRange:       192.0.2.0 - 192.0.2.255
      """

      assert {:ok, cidrs} = SurfaceMap.cidrs_from_whois(blob)
      by_cidr = Map.new(cidrs, &{&1.cidr, &1})

      assert Map.has_key?(by_cidr, "198.51.100.0/24")
      assert by_cidr["198.51.100.0/24"].source == :whois
      assert by_cidr["198.51.100.0/24"].org == "Example Org"

      assert Map.has_key?(by_cidr, "192.0.2.0/24")
      assert by_cidr["192.0.2.0/24"].source == :netrange
      assert by_cidr["192.0.2.0/24"].org == "Example Org"
    end

    test "parses route lines and attaches org-name" do
      blob = """
      org-name:       Documentation LLC
      route:          203.0.113.0/24
      origin:         AS64500
      """

      assert {:ok, [cidr]} = SurfaceMap.cidrs_from_whois(blob)
      assert cidr.cidr == "203.0.113.0/24"
      assert cidr.source == :route
      assert cidr.org == "Documentation LLC"
    end

    test "collapses duplicate CIDRs from mixed sources" do
      blob = """
      CIDR:           198.51.100.0/24
      route:          198.51.100.0/24
      CIDR:           198.51.100.0/24
      NetRange:       198.51.100.0 - 198.51.100.255
      """

      assert {:ok, cidrs} = SurfaceMap.cidrs_from_whois(blob)
      assert length(cidrs) == 1
      assert hd(cidrs).cidr == "198.51.100.0/24"
      assert hd(cidrs).source == :whois
    end

    test "ignores junk and non-exact NetRange" do
      blob = """
      Comment:        not a prefix
      NetRange:       192.0.2.1 - 192.0.2.255
      garbage 10.0.0.0/8 is not on a CIDR line
      """

      assert {:ok, []} = SurfaceMap.cidrs_from_whois(blob)
    end

    test "empty whois returns {:ok, []}" do
      assert {:ok, []} = SurfaceMap.cidrs_from_whois("")
      assert {:ok, []} = SurfaceMap.cidrs_from_whois("   \n\n  ")
    end

    test "returns error for non-string input" do
      assert {:error, reason} = SurfaceMap.cidrs_from_whois(nil)
      assert is_binary(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # vhost_candidates/1
  # ---------------------------------------------------------------------------

  describe "vhost_candidates/1" do
    test "includes admin.example.com from the built-in prefix list" do
      assert {:ok, vhosts} = SurfaceMap.vhost_candidates(domain: "example.com")
      hosts = Enum.map(vhosts, & &1.host)

      assert "admin.example.com" in hosts
      assert "www.example.com" in hosts
      assert "api.example.com" in hosts

      admin = Enum.find(vhosts, &(&1.host == "admin.example.com"))
      assert admin.kind == :prefix
      assert admin.parent == "example.com"
    end

    test "normalizes and dedupes names like Foo.EXAMPLE.com" do
      assert {:ok, vhosts} =
               SurfaceMap.vhost_candidates(
                 domain: "EXAMPLE.com",
                 names: ["Foo.EXAMPLE.com", "foo.example.com", "FOO.example.com."]
               )

      foos = Enum.filter(vhosts, &(&1.host == "foo.example.com"))
      assert length(foos) == 1
      assert hd(foos).parent == "example.com"
      assert hd(foos).kind in [:given, :san]
    end

    test "returns error when :domain is missing" do
      assert {:error, reason} = SurfaceMap.vhost_candidates([])
      assert reason =~ "domain"

      assert {:error, reason2} = SurfaceMap.vhost_candidates(names: ["www.example.com"])
      assert reason2 =~ "domain"
    end

    test "returns unique hosts even when a name matches a prefix" do
      assert {:ok, vhosts} =
               SurfaceMap.vhost_candidates(
                 domain: "example.com",
                 names: ["admin.example.com"]
               )

      admins = Enum.filter(vhosts, &(&1.host == "admin.example.com"))
      assert length(admins) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # ingest_httpx/1
  # ---------------------------------------------------------------------------

  describe "ingest_httpx/1" do
    test "parses JSONL with two hosts" do
      jsonl = """
      {"url":"https://admin.example.com","host":"198.51.100.10","status-code":200,"title":"Admin","webserver":"nginx"}
      {"url":"https://www.example.com","input":"www.example.com","status-code":301,"title":"Home"}
      """

      assert {:ok, hosts} = SurfaceMap.ingest_httpx(jsonl)
      assert length(hosts) == 2

      by_host = Map.new(hosts, &{&1.host, &1})
      assert by_host["admin.example.com"].status == 200
      assert by_host["admin.example.com"].title == "Admin"
      assert by_host["www.example.com"].status == 301
      assert by_host["www.example.com"].title == "Home"
    end

    test "parses plain probe lines and host-header vhosts" do
      blob = """
      admin.example.com [200] [Admin]
      {"url":"https://198.51.100.20","host-header":"intranet.example.com","status-code":200,"title":"Intranet"}
      not a useful line
      """

      assert {:ok, hosts} = SurfaceMap.ingest_httpx(blob)
      by_host = Map.new(hosts, &{&1.host, &1})

      assert by_host["admin.example.com"].status == 200
      assert by_host["admin.example.com"].title == "Admin"
      assert by_host["198.51.100.20"].vhost == "intranet.example.com"
      assert by_host["198.51.100.20"].status == 200
    end

    test "empty or junk input returns {:ok, []}" do
      assert {:ok, []} = SurfaceMap.ingest_httpx("")
      assert {:ok, []} = SurfaceMap.ingest_httpx("\n{}\nnot json\n")
    end

    test "returns error for non-string input" do
      assert {:error, reason} = SurfaceMap.ingest_httpx(%{})
      assert is_binary(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # in_owned_cidr?/2
  # ---------------------------------------------------------------------------

  describe "in_owned_cidr?/2" do
    test "matches IPv4 addresses inside a CIDR and rejects outside" do
      cidrs = ["198.51.100.0/24"]

      assert SurfaceMap.in_owned_cidr?("198.51.100.20", cidrs)
      refute SurfaceMap.in_owned_cidr?("198.51.101.1", cidrs)
    end

    test "invalid IP returns false" do
      refute SurfaceMap.in_owned_cidr?("not-an-ip", ["198.51.100.0/24"])
      refute SurfaceMap.in_owned_cidr?("", ["198.51.100.0/24"])
      refute SurfaceMap.in_owned_cidr?("198.51.100.20", [])
    end
  end

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  describe "render/1" do
    test "prints a compact recon map" do
      text =
        SurfaceMap.render(%{
          cidrs: [%{cidr: "198.51.100.0/24", source: :whois, org: "Example Org"}],
          vhosts: [%{host: "admin.example.com", kind: :prefix, parent: "example.com"}],
          live: [%{host: "admin.example.com", status: 200, title: "Admin", vhost: nil}]
        })

      assert is_binary(text)
      assert text =~ "198.51.100.0/24"
      assert text =~ "admin.example.com"
      assert text =~ "200"
    end
  end
end
