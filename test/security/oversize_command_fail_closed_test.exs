defmodule OptimalSystemAgent.Security.OversizeCommandFailClosedTest do
  @moduledoc """
  `CommandVariants.variants/1` bailed out of de-obfuscation for commands over
  20 KB by returning `[command]` — a size bound that failed OPEN. Padding a
  catastrophic command past the limit therefore reached the hard-deny tier as a
  raw, still-quoted string and sailed through it.

  A size bound on a *safety* analysis must fail closed: when we cannot fully
  analyse the input, it is not safe, it is unknown.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Safety.CommandVariants
  alias OptimalSystemAgent.Agent.Safety.DangerousCommands

  # 20_000 is @max_length; go comfortably past it.
  defp pad(n \\ 25_000), do: String.duplicate("#", n)

  describe "oversize commands" do
    test "a padded `rm -rf /` is still blocked" do
      cmd = ~s(rm -rf "/" ; echo #{pad()})
      assert byte_size(cmd) > 20_000

      assert {:blocked, _} = DangerousCommands.check_command(cmd)
      assert DangerousCommands.catastrophic_destruction?(cmd)
    end

    test "a padded quoted-root rm wrapped in bash -c is still blocked" do
      cmd = ~s(bash -c "rm -rf '/'" # #{pad()})
      assert byte_size(cmd) > 20_000

      assert {:blocked, _} = DangerousCommands.check_command(cmd)
      assert DangerousCommands.catastrophic_destruction?(cmd)
    end

    test "a padded mkfs is still blocked" do
      cmd = ~s(mkfs.ext4 /dev/sda1 # #{pad()})
      assert {:blocked, _} = DangerousCommands.check_command(cmd)
      assert DangerousCommands.catastrophic_destruction?(cmd)
    end

    test "an oversize command is reported as not fully analysed" do
      refute CommandVariants.fully_analyzed?(pad())
      assert CommandVariants.fully_analyzed?("echo hi")
    end

    test "an oversize but harmless command is not falsely reported catastrophic" do
      cmd = "echo #{pad()}"
      refute DangerousCommands.catastrophic_destruction?(cmd)
    end
  end

  describe "variant truncation" do
    test "truncation is reported, so a caller can fail closed on it" do
      # A deeply nested wrapper chain produces more variants than @max_variants.
      nested =
        Enum.reduce(1..40, ~s(rm -rf /), fn _, acc ->
          ~s(sudo env bash -c #{inspect(acc)})
        end)

      # Whatever the variant budget does, the classification must not weaken.
      assert DangerousCommands.catastrophic_destruction?(nested) or
               not CommandVariants.fully_analyzed?(nested)
    end
  end

  describe "under-limit behaviour is unchanged" do
    test "normal dangerous commands still block" do
      assert {:blocked, _} = DangerousCommands.check_command("rm -rf /")
      assert {:blocked, _} = DangerousCommands.check_command(~s(rm -rf "/"))
    end

    test "normal safe commands still pass" do
      assert DangerousCommands.check_command("ls -la") == :ok
      assert DangerousCommands.check_command("git status") == :ok
    end
  end
end
