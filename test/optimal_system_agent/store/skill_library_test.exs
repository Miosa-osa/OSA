defmodule OptimalSystemAgent.Store.SkillLibraryTest do
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Store.SkillLibrary

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "osa-skill-lib-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    prev = Application.get_env(:optimal_system_agent, :skills_dir)
    Application.put_env(:optimal_system_agent, :skills_dir, dir)

    on_exit(fn ->
      if prev, do: Application.put_env(:optimal_system_agent, :skills_dir, prev)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  defp good(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Restart the OSA gateway safely",
        "description" => "Kill and restart the gateway without losing sessions",
        "when_to_use" => "When the gateway is unresponsive or port 18789 is stuck",
        "body" =>
          "1. ss -ltnp | rg 18789 to find it. 2. Stop via the app. 3. Relaunch and verify sessions reattach.",
        "tags" => ["gateway", "ops"]
      },
      overrides
    )
  end

  describe "save_skill capture gate" do
    test "stores a high-signal skill and round-trips it" do
      assert {:ok, skill} = SkillLibrary.save_skill(good())
      assert skill["slug"] == "restart-the-osa-gateway-safely"
      assert SkillLibrary.get_skill(skill["slug"])["title"] == good()["title"]
    end

    test "rejects a trivial one-off (thin body)" do
      assert {:error, reason} = SkillLibrary.save_skill(good(%{"body" => "ls"}))
      assert reason =~ "too thin"
      assert SkillLibrary.list_skills() == []
    end

    test "rejects a skill with no real trigger" do
      attrs = good() |> Map.delete("when_to_use") |> Map.put("description", "x")
      assert {:error, reason} = SkillLibrary.save_skill(attrs)
      assert reason =~ "trigger"
    end
  end

  describe "dedup / upsert" do
    test "re-saving the same slug updates in place and preserves the use count" do
      assert {:ok, s1} = SkillLibrary.save_skill(good())
      {:ok, _} = SkillLibrary.increment_use(s1["slug"])
      {:ok, _} = SkillLibrary.increment_use(s1["slug"])

      assert {:ok, s2} =
               SkillLibrary.save_skill(good(%{"description" => "Updated description here now"}))

      assert s2["slug"] == s1["slug"]
      assert s2["uses"] == 2
      assert s2["created_at"] == s1["created_at"]
      assert length(SkillLibrary.list_skills()) == 1
    end
  end

  describe "find_skills (ranked retrieval)" do
    test "returns relevant skills and ignores irrelevant ones" do
      {:ok, _} = SkillLibrary.save_skill(good())

      {:ok, _} =
        SkillLibrary.save_skill(
          good(%{
            "title" => "Render a mandelbrot fractal",
            "slug" => "mandelbrot",
            "description" => "Draw the mandelbrot set as coloured ASCII art",
            "when_to_use" => "When asked to draw a fractal image on screen",
            "body" =>
              "1. Iterate z = z^2 + c per pixel. 2. Map escape count to a colour ramp. 3. Print the grid.",
            "tags" => ["graphics", "fractal"]
          })
        )

      results = SkillLibrary.find_skills("gateway is stuck, restart it")
      slugs = Enum.map(results, & &1["slug"])

      assert "restart-the-osa-gateway-safely" in slugs
      refute "mandelbrot" in slugs
    end

    test "fetch by exact slug via find_skill path still works" do
      {:ok, s} = SkillLibrary.save_skill(good())
      assert SkillLibrary.get_skill(s["slug"])["slug"] == s["slug"]
    end
  end
end
