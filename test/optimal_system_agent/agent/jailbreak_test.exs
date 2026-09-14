defmodule OptimalSystemAgent.Agent.JailbreakTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Jailbreak

  @tmp_home Path.join(
              System.tmp_dir!(),
              "osa-jailbreak-test-#{System.unique_integer([:positive])}"
            )

  setup do
    File.mkdir_p!(@tmp_home)
    System.put_env("OSA_HOME", @tmp_home)

    on_exit(fn ->
      System.delete_env("OSA_HOME")
      File.rm_rf!(@tmp_home)
    end)

    :ok
  end

  defp default_prompt_file,
    do: Path.join(System.get_env("OSA_HOME") || System.user_home!(), "prompts/jailbreak.md")

  # ── /jailbreak core contract ────────────────────────────────────────

  test "inactive by default: no block, no badge" do
    refute Jailbreak.active?()
    assert "" = Jailbreak.system_block()
    assert "" = Jailbreak.badge()
  end

  test "/jailbreak on arms the bundled text and shows LIBERATED" do
    # No user file → falls back to priv/prompts/jailbreak.md (shipped with repo)
    refute File.exists?(default_prompt_file())
    assert :ok = Jailbreak.set(true)
    assert Jailbreak.active?()

    block = Jailbreak.system_block()
    assert is_binary(block) and String.length(block) > 100
    # The shipped text (Ds.txt content, ENI persona) must be what gets injected.
    assert block =~ "ENI" or block =~ "LO",
           "bundled jailbreak text missing from priv/prompts/jailbreak.md"

    assert Jailbreak.badge() =~ "LIBERATED"
  end

  test "/jailbreak off disarms: empty block, no badge" do
    :ok = Jailbreak.set(true)
    :ok = Jailbreak.set(false)
    refute Jailbreak.active?()
    assert "" = Jailbreak.system_block()
    assert "" = Jailbreak.badge()
  end

  test "custom file path is used and remembered across disarm/rearm" do
    custom = Path.join(@tmp_home, "my_jailbreak.txt")
    File.write!(custom, "CUSTOM-OPERATOR-OVERRIDE text")

    :ok = Jailbreak.set(true, custom)
    assert Jailbreak.system_block() =~ "CUSTOM-OPERATOR-OVERRIDE"

    # Disarm + rearm without a path → still points at the custom file.
    :ok = Jailbreak.set(false)
    :ok = Jailbreak.set(true)
    assert Jailbreak.system_block() =~ "CUSTOM-OPERATOR-OVERRIDE"
    assert Jailbreak.file_path() == custom
  end

  test "~ expansion in a custom path" do
    # "~" must expand against $HOME, so the fixture lives at HOME's root.
    custom = Path.join(System.user_home!(), "osa_jb_tilde_test.txt")
    File.write!(custom, "TILDE-PATH text")

    on_exit(fn -> File.rm(custom) end)
    rel = String.replace_leading(custom, System.user_home!(), "~")

    :ok = Jailbreak.set(true, rel)
    assert Jailbreak.system_block() =~ "TILDE-PATH"
  end

  test "missing custom path is refused with :empty_prompt and nothing is armed" do
    missing = Path.join(@tmp_home, "does_not_exist.txt")
    assert {:error, :empty_prompt} = Jailbreak.set(true, missing)
    refute Jailbreak.active?()
    assert "" = Jailbreak.system_block()
  end

  test "user override ~/.osa/prompts/jailbreak.md beats the bundled file" do
    File.mkdir_p!(Path.dirname(default_prompt_file()))
    File.write!(default_prompt_file(), "USER-OVERRIDE jailbreak text")
    :ok = Jailbreak.set(true)
    assert Jailbreak.system_block() =~ "USER-OVERRIDE"
  end

  test "~/.osa/jailbreak.json persists the armed state and custom file" do
    custom = Path.join(@tmp_home, "persisted.txt")
    File.write!(custom, "PERSISTED text")
    :ok = Jailbreak.set(true, custom)

    meta = Jason.decode!(File.read!(Path.join(@tmp_home, "jailbreak.json")))
    assert meta["enabled"] == true
    assert meta["file"] == custom
  end

  test "preview is a short non-empty line of the active text" do
    :ok = Jailbreak.set(true)
    preview = Jailbreak.preview()
    assert is_binary(preview) and String.length(preview) >= 1
    refute String.contains?(preview, "\n")
  end

  test "badge is empty once disarmed even though a prior arm left state behind" do
    # A prior test armed + disarmed; the badge must track live state, not stale caches.
    :ok = Jailbreak.set(false)
    assert "" = Jailbreak.badge()
  end

  # ── prompt position ────────────────────────────────────────────────

  test "armed block is the FIRST text of the system message, before the Soul base" do
    custom = Path.join(@tmp_home, "position_probe.txt")
    File.write!(custom, "JB-POSITION-PROBE operator override")
    :ok = Jailbreak.set(true, custom)

    state = %{
      session_id: "jailbreak-position-#{System.unique_integer([:positive])}",
      messages: [%{role: "user", content: "where does the block sit?"}],
      working_dir: File.cwd!(),
      channel: :cli,
      provider: :ollama,
      model: nil,
      permission_tier: :full
    }

    %{messages: assembled} = OptimalSystemAgent.Agent.Context.build(state)

    # The system message is the first entry; its text must OPEN with the block.
    system_text =
      case assembled do
        [%{role: "system", content: text} | _] when is_binary(text) -> text
        [%{role: "system", content: blocks} | _] when is_list(blocks) -> nil
        _ -> nil
      end

    assert is_binary(system_text),
           "expected a plain-string system message on the :ollama route"

    assert String.starts_with?(system_text, "JB-POSITION-PROBE"),
           "jailbreak block must be the first text of the system prompt"

    # And it must come BEFORE the Soul base's own opening, not merely be present.
    assert String.starts_with?(system_text, "JB-POSITION-PROBE operator override\n\n"),
           "block must be followed by the static base, not spliced into it"
  end
end
