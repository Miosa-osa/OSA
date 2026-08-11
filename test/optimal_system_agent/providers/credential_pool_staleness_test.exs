defmodule OptimalSystemAgent.Providers.CredentialPoolStalenessTest do
  @moduledoc """
  The pool snapshots every `*_API_KEY` in `init/1` and `get_key/1` OUTRANKS
  `Application.get_env/2` in the providers. So a key replaced at runtime — the
  in-UI key screen, the HTTP `POST /key` route, `osa setup` in the same node —
  left the pool serving the key captured at boot, and the user watched their
  old, possibly revoked, key be rejected no matter how many times they entered
  the right one.

  `reload/0` existed and its docstring described exactly this bug, but only
  three call sites reached it. The fix is to reload from the function every
  write path funnels through rather than from each call site, so the next
  writer added cannot miss it.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Onboarding
  alias OptimalSystemAgent.Providers.CredentialPool

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-pool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev_home = System.get_env("OSA_HOME")
    prev_key = System.get_env("GROQ_API_KEY")
    System.put_env("OSA_HOME", dir)

    pid = Process.whereis(CredentialPool)

    on_exit(fn ->
      if prev_home, do: System.put_env("OSA_HOME", prev_home), else: System.delete_env("OSA_HOME")
      if prev_key, do: System.put_env("GROQ_API_KEY", prev_key), else: System.delete_env("GROQ_API_KEY")
      Application.delete_env(:optimal_system_agent, :groq_api_key)
      if pid, do: CredentialPool.reload()
      File.rm_rf(dir)
    end)

    if is_nil(pid), do: {:ok, _} = CredentialPool.start_link([])

    :ok
  end

  describe "a key replaced at runtime takes effect without a restart" do
    test "the pool serves the NEW key after a provider-key write" do
      # The boot snapshot: a key that is about to be revoked.
      System.put_env("GROQ_API_KEY", "gsk-old-and-revoked")
      CredentialPool.reload()
      assert CredentialPool.get_key(:groq) == "gsk-old-and-revoked"

      # The user corrects it. This is the shared write path that every
      # surface — the wizard, `osa setup`, and the authenticated HTTP
      # `POST /key` route — funnels through.
      :ok = Onboarding.upsert_provider_key(%{provider: "groq", api_key: "gsk-corrected", set_active: false})

      assert CredentialPool.get_key(:groq) == "gsk-corrected",
             "the pool outranks Application env, so a stale snapshot here means the " <>
               "corrected key is never used and the revoked one is retried forever"
    end

    test "the same holds for the set_active path" do
      System.put_env("GROQ_API_KEY", "gsk-old-and-revoked")
      CredentialPool.reload()
      assert CredentialPool.get_key(:groq) == "gsk-old-and-revoked"

      :ok = Onboarding.upsert_provider_key(%{provider: "groq", api_key: "gsk-corrected", set_active: true})

      assert CredentialPool.get_key(:groq) == "gsk-corrected"
    end

    test "apply_provider_key/2 alone also refreshes the pool" do
      System.put_env("GROQ_API_KEY", "gsk-old")
      CredentialPool.reload()
      assert CredentialPool.get_key(:groq) == "gsk-old"

      :ok = Onboarding.apply_provider_key("groq", "gsk-newer")

      assert CredentialPool.get_key(:groq) == "gsk-newer"
    end
  end

  describe "reload/0 is safe to call from anywhere" do
    test "it never raises, even with no keys configured at all" do
      System.delete_env("GROQ_API_KEY")
      assert CredentialPool.reload() == :ok
      assert CredentialPool.get_key(:groq) in [nil, ""] or is_binary(CredentialPool.get_key(:groq))
    end
  end
end
