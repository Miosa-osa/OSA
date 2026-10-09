defmodule OptimalSystemAgent.Onboarding.Provisioned do
  @moduledoc """
  Is this OSA already configured by its environment or its platform?

  Onboarding (the setup wizard, the TUI's first-run provider picker) exists for
  one person: a local user who runs `osa` by hand on a machine where nothing
  says which model to use. Everyone else has been configured before OSA
  started, and asking them again is at best noise and at worst a wizard
  blocking on a stdin nobody is attached to. OSA is provisioned, and onboarding
  never runs, when any of these holds:

    * `OSA_SKIP_ONBOARDING` is truthy (`1`, `true`, `yes`, `on`), which the
      launchers also set for `--no-onboarding`;
    * a provider is configured in the environment (`provider_keys/0`): a
      provider choice (`OSA_DEFAULT_PROVIDER`, `OSA_MODEL`), a vendor key, an
      OpenAI- or Anthropic-compatible base URL, or the MIOSA AI Gateway;
    * a platform-written environment file names one: `OSA_PLATFORM_ENV_FILE`,
      default `/opt/osagent/env.sh`, which MIOSA's envd writes on
      `/osa/configure` (`export KEY='value'` lines);
    * `~/.osa/.env` names one, or sets `OSA_SKIP_ONBOARDING`.

  Pure where it can be: `env_configured?/1` and `file_configured?/1` take
  their inputs, so the decision table is testable without touching the real
  environment or filesystem.
  """

  # Every variable that, set and non-blank, means "a model provider has been
  # chosen or credentialed for this OSA". bin/osa and scripts/install.sh carry
  # the same list for the launcher-side wizard gate; a test keeps them in sync.
  @provider_keys ~w(
    OSA_DEFAULT_PROVIDER OSA_MODEL
    MIOSA_AI_GATEWAY_URL
    OPENAI_API_KEY OPENAI_BASE_URL
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
    OLLAMA_API_KEY
    OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY GROQ_API_KEY
    DEEPSEEK_API_KEY MISTRAL_API_KEY XAI_API_KEY TOGETHER_API_KEY
    FIREWORKS_API_KEY CEREBRAS_API_KEY COHERE_API_KEY PERPLEXITY_API_KEY
    MOONSHOT_API_KEY QWEN_API_KEY ZHIPU_API_KEY SAMBANOVA_API_KEY
    HYPERBOLIC_API_KEY VOLCENGINE_API_KEY BAICHUAN_API_KEY REPLICATE_API_KEY
  )

  @skip_key "OSA_SKIP_ONBOARDING"
  @platform_env_file "/opt/osagent/env.sh"
  @truthy ~w(1 true yes on)

  @doc "The variables that count as a configured provider."
  @spec provider_keys() :: [String.t()]
  def provider_keys, do: @provider_keys

  @doc """
  The platform environment file consulted: `OSA_PLATFORM_ENV_FILE`, default
  `/opt/osagent/env.sh`; nil when the variable is set but empty (disabled).
  `config/runtime.exs` loads the same file as provider defaults.
  """
  @spec platform_env_file() :: String.t() | nil
  def platform_env_file do
    case System.get_env("OSA_PLATFORM_ENV_FILE") do
      nil -> @platform_env_file
      "" -> nil
      path -> path
    end
  end

  @doc """
  True when onboarding must not run. Checks the live environment, the
  platform environment file and `dotenv_path` (`~/.osa/.env`).
  """
  @spec provisioned?(String.t() | nil) :: boolean()
  def provisioned?(dotenv_path \\ nil) do
    platform_file = platform_env_file()

    env_configured?(System.get_env()) or
      (is_binary(platform_file) and file_configured?(platform_file)) or
      (is_binary(dotenv_path) and file_configured?(dotenv_path))
  end

  @doc "True when an environment map skips onboarding or configures a provider."
  @spec env_configured?(%{optional(String.t()) => String.t()}) :: boolean()
  def env_configured?(env) when is_map(env) do
    skip_requested?(Map.get(env, @skip_key)) or
      Enum.any?(@provider_keys, &present?(Map.get(env, &1)))
  end

  @doc "True when an env-style file skips onboarding or configures a provider."
  @spec file_configured?(String.t()) :: boolean()
  def file_configured?(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> content |> parse_env() |> env_configured?()
      _ -> false
    end
  end

  @doc "True for an `OSA_SKIP_ONBOARDING` value that asks to skip."
  @spec skip_requested?(String.t() | nil) :: boolean()
  def skip_requested?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in @truthy

  def skip_requested?(_), do: false

  @doc """
  Parse `KEY=value` lines, with or without a leading `export `, and with
  single- or double-quoted values (envd writes `export KEY='value'`). Enough
  to answer "is this key set"; not a shell.
  """
  @spec parse_env(String.t()) :: %{String.t() => String.t()}
  def parse_env(content) when is_binary(content) do
    content
    |> OptimalSystemAgent.Config.Dotenv.strip_invisible()
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      line = line |> String.trim() |> String.replace_prefix("export ", "") |> String.trim()

      with false <- line == "" or String.starts_with?(line, "#"),
           [key, value] <- String.split(line, "=", parts: 2),
           key = String.trim(key),
           true <- Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
        Map.put_new(acc, key, unquote_value(String.trim(value)))
      else
        _ -> acc
      end
    end)
  end

  defp unquote_value("'" <> rest) do
    rest |> String.trim_trailing("'") |> String.replace("'\\''", "'")
  end

  defp unquote_value("\"" <> rest), do: String.trim_trailing(rest, "\"")
  defp unquote_value(value), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
