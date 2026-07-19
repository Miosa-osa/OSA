defmodule OptimalSystemAgent.Memory.SkillGeneratorTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Memory.SkillGenerator

  describe "auto-generation flag (default OFF)" do
    test "generate_all_pending is a no-op when the flag is unset" do
      prev = Application.get_env(:optimal_system_agent, :auto_skill_generation)
      Application.delete_env(:optimal_system_agent, :auto_skill_generation)
      on_exit(fn -> if prev, do: Application.put_env(:optimal_system_agent, :auto_skill_generation, prev) end)

      assert SkillGenerator.generate_all_pending() == {:ok, 0}
    end
  end

  describe "skill_worthy?/1 quality gate" do
    test "rejects a recurring tool SUCCESS outcome (the old junk factory)" do
      refute SkillGenerator.skill_worthy?(%{
               description: "Tool file_read succeeded",
               trigger: "success:file_read",
               response: "continue",
               category: "success"
             })
    end

    test "rejects a recurring ERROR outcome" do
      refute SkillGenerator.skill_worthy?(%{
               description: "io_error/permission_denied in file_read",
               trigger: "error:file_read:permission_denied",
               response: "check the path and permissions",
               category: "io_error"
             })
    end

    test "rejects a trivial control-signal response even without an outcome trigger" do
      refute SkillGenerator.skill_worthy?(%{
               description: "Some recurring thing that happens a lot here",
               trigger: "When this recurring situation shows up again",
               response: "continue",
               category: "context"
             })
    end

    test "rejects a thin one-line body" do
      refute SkillGenerator.skill_worthy?(%{
               description: "Deploy the service to production quickly",
               trigger: "When deploying the service to production",
               response: "run deploy.sh",
               category: "context"
             })
    end

    test "accepts a genuine multi-step reusable procedure" do
      assert SkillGenerator.skill_worthy?(%{
               description: "Recover a wedged build cache",
               trigger: "When the build fails with a stale cache error after a dependency bump",
               response:
                 "1. Stop the build. 2. Clear _build and deps. 3. Re-fetch deps. 4. Recompile and verify the failing target builds.",
               category: "solution"
             })
    end

    test "rejects a non-map" do
      refute SkillGenerator.skill_worthy?("nope")
    end
  end
end
