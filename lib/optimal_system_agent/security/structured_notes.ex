defmodule OptimalSystemAgent.Security.StructuredNotes do
  @moduledoc """
  Schema-validated security notes for penetration testing engagements.

  Adapted from PentestAgent's notes system. Notes have categories with required
  fields per category, plus structured metadata (services, endpoints,
  technologies). This is the foundation for the ShadowGraph knowledge graph.

  ## Categories

    * `:credential` — requires `username`, `target`, and one of `password`/`protocol`
    * `:vulnerability` — requires `target`, and one of `cve`/`weaknesses`
    * `:finding` — requires `target`, and one of `services`/`endpoints`/`technologies`/`port`
    * `:artifact` — requires `target`
    * `:info` — no required fields

  ## Structured metadata

  Services: `[%{port: 22, product: "OpenSSH", version: "8.9", protocol: "tcp"}]`
  Endpoints: `[%{path: "/api/users", methods: ["GET", "POST"]}]`
  Technologies: `[%{name: "nginx", version: "1.21"}]`

  ## Usage

      # Create a credential note
      {:ok, note} = StructuredNotes.create("creds_ssh", %{
        category: :credential,
        content: "SSH credentials found via hydra",
        username: "root",
        password: "toor",
        target: "10.0.0.1",
        protocol: "ssh"
      })

      # Create a vulnerability note
      {:ok, note} = StructuredNotes.create("vuln_sqli", %{
        category: :vulnerability,
        content: "SQL injection in /api/users?id=1",
        target: "https://example.com",
        cve: "CVE-2024-1234",
        confidence: :high,
        status: :confirmed
      })

      # Validate without creating
      :ok = StructuredNotes.validate(%{category: :credential, username: "admin", target: "10.0.0.1", password: "pass"})
      {:error, reason} = StructuredNotes.validate(%{category: :credential, target: "10.0.0.1"})
  """

  require Logger

  @categories ~w(credential vulnerability finding artifact info)a

  @host_specific_fields ~w(services endpoints technologies port)a

  @category_requirements %{
    credential: %{
      required: [:username, :target],
      one_of: [:password, :protocol]
    },
    vulnerability: %{
      required: [:target],
      one_of: [:cve, :weaknesses]
    },
    finding: %{
      required: [:target],
      one_of: [:services, :endpoints, :technologies, :port]
    },
    artifact: %{
      required: [:target],
      one_of: []
    },
    info: %{
      required: [],
      one_of: []
    }
  }

  @type category :: :credential | :vulnerability | :finding | :artifact | :info
  @type confidence :: :high | :medium | :low
  @type status :: :open | :closed | :filtered | :confirmed | :potential

  @type note :: %{
          key: String.t(),
          category: category(),
          content: String.t(),
          confidence: confidence(),
          status: status(),
          target: String.t() | nil,
          source: String.t() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          protocol: String.t() | nil,
          port: String.t() | nil,
          cve: String.t() | nil,
          url: String.t() | nil,
          evidence_path: String.t() | nil,
          services: [map()] | nil,
          endpoints: [map()] | nil,
          technologies: [map()] | nil,
          weaknesses: [map()] | nil,
          affected_versions: map() | nil,
          metadata: map()
        }

  @doc "List of valid categories."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "Validate a note's fields against its category schema."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{category: category} = data) when category in @categories do
    requirements = Map.get(@category_requirements, category, %{required: [], one_of: []})

    # Check required fields
    missing_required =
      requirements[:required]
      |> Enum.reject(fn field -> present?(Map.get(data, field)) end)

    if missing_required != [] do
      {:error, "Missing required fields for #{category}: #{inspect(missing_required)}"}
    else
      # Check one_of constraints
      check_one_of(data, category, requirements[:one_of])
    end
  end

  def validate(%{category: category}) do
    {:error, "Invalid category: #{inspect(category)}. Valid: #{inspect(@categories)}"}
  end

  def validate(_) do
    {:error, "Missing required field: category"}
  end

  defp check_one_of(_data, _category, []), do: :ok
  defp check_one_of(_data, _category, nil), do: :ok

  defp check_one_of(data, category, one_of) when is_list(one_of) do
    # one_of is a single group of fields — at least one must be present
    has_any = Enum.any?(one_of, fn field -> present?(Map.get(data, field)) end)

    if has_any do
      check_host_specific_target(data)
    else
      field_list = one_of |> Enum.map(&Atom.to_string/1) |> Enum.join("' or '")
      {:error, "At least one of '#{field_list}' is required for category '#{category}'"}
    end
  end

  defp check_host_specific_target(data) do
    has_host_data =
      @host_specific_fields
      |> Enum.any?(fn field -> present?(Map.get(data, field)) end)

    if has_host_data and not present?(Map.get(data, :target)) do
      fields =
        @host_specific_fields |> Enum.filter(&present?(Map.get(data, &1))) |> Enum.join(", ")

      {:error, "'target' field is required when providing host-specific data (#{fields})"}
    else
      :ok
    end
  end

  @doc "Create a structured note with validation."
  @spec create(String.t(), map()) :: {:ok, note()} | {:error, String.t()}
  def create(key, data) when is_binary(key) and is_map(data) do
    case validate(data) do
      :ok ->
        note = build_note(key, data)
        {:ok, note}

      {:error, _} = error ->
        error
    end
  end

  @doc "Build a note struct from validated data."
  @spec build_note(String.t(), map()) :: note()
  def build_note(key, data) do
    %{
      key: key,
      category: Map.get(data, :category, :info),
      content: Map.get(data, :content, ""),
      confidence: Map.get(data, :confidence, :medium),
      status: Map.get(data, :status, :confirmed),
      target: Map.get(data, :target),
      source: Map.get(data, :source),
      username: Map.get(data, :username),
      password: Map.get(data, :password),
      protocol: Map.get(data, :protocol),
      port: Map.get(data, :port),
      cve: Map.get(data, :cve),
      url: Map.get(data, :url),
      evidence_path: Map.get(data, :evidence_path),
      services: Map.get(data, :services),
      endpoints: Map.get(data, :endpoints),
      technologies: Map.get(data, :technologies),
      weaknesses: Map.get(data, :weaknesses),
      affected_versions: Map.get(data, :affected_versions),
      metadata: Map.get(data, :metadata, %{})
    }
  end

  @doc "Extract hosts (IPs and hostnames) from a note's content and metadata."
  @spec extract_hosts(note()) :: [String.t()]
  def extract_hosts(%{content: content, target: target, source: source}) do
    ip_pattern = ~r/\b(?:\d{1,3}\.){3}\d{1,3}\b/

    from_content =
      case Regex.scan(ip_pattern, content || "") do
        [] -> []
        matches -> List.flatten(matches)
      end

    from_metadata = Enum.reject([target, source], &is_nil/1)

    (from_metadata ++ from_content)
    |> Enum.uniq()
  end

  @doc "Check if a note has host-specific structured data."
  @spec has_host_data?(note()) :: boolean()
  def has_host_data?(note) do
    @host_specific_fields
    |> Enum.any?(fn field -> present?(Map.get(note, field)) end)
  end

  @doc "Get all services from a note (structured + port field)."
  @spec get_services(note()) :: [map()]
  def get_services(%{services: services}) when is_list(services) and services != [], do: services

  def get_services(%{port: port, protocol: proto}) when is_binary(port) do
    [%{port: String.to_integer(port), protocol: proto || "tcp", product: "", version: ""}]
  end

  def get_services(_), do: []

  @doc "Get all endpoints from a note."
  @spec get_endpoints(note()) :: [map()]
  def get_endpoints(%{endpoints: endpoints}) when is_list(endpoints) and endpoints != [],
    do: endpoints

  def get_endpoints(_), do: []

  @doc "Get all technologies from a note."
  @spec get_technologies(note()) :: [map()]
  def get_technologies(%{technologies: tech}) when is_list(tech) and tech != [], do: tech
  def get_technologies(_), do: []

  # ── Private ──────────────────────────────────────────────────────────────

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?([]), do: false
  defp present?(%{} = m) when map_size(m) == 0, do: false
  defp present?(_), do: true
end
