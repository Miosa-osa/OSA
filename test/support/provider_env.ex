defmodule OptimalSystemAgent.Test.ProviderEnv do
  @moduledoc """
  "No model provider is configured by the environment", for one test.

  Process environment is global and some tests set a provider key
  (`ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`, `OSA_MODEL`, ...) for their own
  purposes. A test whose premise is an unconfigured machine (first-run open
  onboarding routes, an advisor with no credential to resolve) must not read
  whatever another test, or the developer's shell, left behind: it calls
  `isolate/0` in `setup`, which removes every variable
  `Onboarding.Provisioned` treats as configuration (plus the platform env
  file) and restores them all when the test exits.

      setup do
        OptimalSystemAgent.Test.ProviderEnv.isolate()
      end
  """

  alias OptimalSystemAgent.Onboarding.Provisioned
  alias OptimalSystemAgent.Test.EnvIsolation

  @spec isolate() :: :ok
  def isolate do
    keys = ["OSA_SKIP_ONBOARDING", "OSA_PLATFORM_ENV_FILE" | Provisioned.provider_keys()]
    EnvIsolation.protect(env: keys)
    Enum.each(keys, &System.delete_env/1)
    System.put_env("OSA_PLATFORM_ENV_FILE", "")
    :ok
  end
end
