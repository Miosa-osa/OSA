defmodule OptimalSystemAgent.Security.FixVerifyTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.FixVerify

  setup do
    dir = Path.join(System.tmp_dir!(), "osa-fix-verify-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        finding_key: "vuln_os_command",
        file_path: "app.py",
        sink: "os.system",
        poc: "os.system(user_input)"
      },
      overrides
    )
  end

  defp checker_seq(before_tuple, after_tuple) do
    fn
      :before, _finding, _opts -> before_tuple
      :after, _finding, _opts -> after_tuple
    end
  end

  describe "verify/2 with injected checker" do
    test "before vulnerable and after fixed sets verified_fixed?" do
      checker = checker_seq({:vulnerable, "sink present"}, {:fixed, "sink gone"})

      assert {:ok, result} = FixVerify.verify(finding(), checker: checker, apply: false)

      assert result.finding_key == "vuln_os_command"
      assert result.before == :vulnerable
      assert result.after == :fixed
      assert result.verified_fixed? == true
      assert is_binary(result.reason)
      refute result.reason == ""
    end

    test "still vulnerable after does not set verified_fixed?" do
      checker = checker_seq({:vulnerable, "sink present"}, {:vulnerable, "sink still present"})

      assert {:ok, result} = FixVerify.verify(finding(), checker: checker, apply: false)

      assert result.before == :vulnerable
      assert result.after == :vulnerable
      assert result.verified_fixed? == false
      assert is_binary(result.reason)
    end

    test "verified_fixed? is false unless before is vulnerable and after is fixed" do
      cases = [
        {{:fixed, "already gone"}, {:fixed, "still gone"}},
        {{:unknown, "no needle"}, {:fixed, "gone"}},
        {{:vulnerable, "present"}, {:unknown, "could not recheck"}},
        {{:fixed, "gone"}, {:vulnerable, "regressed"}}
      ]

      for {before, afterc} <- cases do
        assert {:ok, result} =
                 FixVerify.verify(finding(), checker: checker_seq(before, afterc), apply: false)

        refute result.verified_fixed?,
               "expected verified_fixed? false for #{inspect(before)} -> #{inspect(afterc)}"
      end
    end

    test "checker error on before returns error and does not call after" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      checker = fn phase, _finding, _opts ->
        Agent.update(agent, fn acc -> acc ++ [phase] end)

        case phase do
          :before -> {:error, "scan failed"}
          :after -> {:fixed, "should not run"}
        end
      end

      assert {:error, reason} = FixVerify.verify(finding(), checker: checker, apply: false)
      assert reason =~ "scan failed"
      assert Agent.get(agent, & &1) == [:before]
    end

    test "checker error on after returns error" do
      checker = checker_seq({:vulnerable, "present"}, {:error, "recheck boom"})

      assert {:error, reason} = FixVerify.verify(finding(), checker: checker, apply: false)
      assert reason =~ "recheck boom"
    end

    test "accepts string-key findings" do
      checker = checker_seq({:vulnerable, "present"}, {:fixed, "gone"})

      assert {:ok, result} =
               FixVerify.verify(
                 %{"finding_key" => "k1", "sink" => "os.system"},
                 checker: checker,
                 apply: false
               )

      assert result.finding_key == "k1"
      assert result.verified_fixed? == true
    end
  end

  describe "static_sink_gone?/2" do
    test "true when needle is not in file contents", %{dir: dir} do
      path = Path.join(dir, "clean.py")
      File.write!(path, "print('hello')\n")
      assert FixVerify.static_sink_gone?(path, "os.system") == true
    end

    test "false when needle is in file contents", %{dir: dir} do
      path = Path.join(dir, "vuln.py")
      File.write!(path, "os.system(user_input)\n")
      assert FixVerify.static_sink_gone?(path, "os.system") == false
    end

    test "false when file is missing", %{dir: dir} do
      path = Path.join(dir, "no-such-file.py")
      refute File.exists?(path)
      assert FixVerify.static_sink_gone?(path, "os.system") == false
    end
  end

  describe "verify/2 default checker" do
    test "apply false: sink present is vulnerable before and after", %{dir: dir} do
      path = Path.join(dir, "app.py")
      File.write!(path, "os.system(cmd)\n")

      assert {:ok, result} =
               FixVerify.verify(finding(%{file_path: path, sink: "os.system"}), apply: false)

      assert result.before == :vulnerable
      assert result.after == :vulnerable
      assert result.verified_fixed? == false
    end

    test "apply true with fix map: before vulnerable after fixed", %{dir: dir} do
      path = Path.join(dir, "app.py")
      File.write!(path, "os.system(cmd)\n")

      assert {:ok, result} =
               FixVerify.verify(
                 finding(%{file_path: path, sink: "os.system"}),
                 apply: true,
                 fix: %{
                   file_path: path,
                   fix_before: "os.system(cmd)",
                   fix_after: "subprocess.run(cmd, shell=False)"
                 }
               )

      assert result.before == :vulnerable
      assert result.after == :fixed
      assert result.verified_fixed? == true
      assert File.read!(path) =~ "subprocess.run(cmd, shell=False)"
      refute File.read!(path) =~ "os.system"
    end

    test "rewrite file between two verify calls: after fix the sink is gone", %{dir: dir} do
      path = Path.join(dir, "app.py")
      File.write!(path, "os.system(cmd)\n")
      f = finding(%{file_path: path, sink: "os.system"})

      assert {:ok, first} = FixVerify.verify(f, apply: false)
      assert first.before == :vulnerable
      assert first.after == :vulnerable
      refute first.verified_fixed?

      File.write!(path, "subprocess.run(cmd, shell=False)\n")

      assert {:ok, second} = FixVerify.verify(f, apply: false)
      assert second.before == :unknown
      assert second.after == :fixed
      refute second.verified_fixed?
    end

    test "uses path key and poc as needle when sink is absent", %{dir: dir} do
      path = Path.join(dir, "app.py")
      File.write!(path, "eval(user_input)\n")

      f = %{finding_key: "vuln_eval", path: path, poc: "eval("}

      assert {:ok, result} =
               FixVerify.verify(f,
                 apply: true,
                 fix: %{file_path: path, fix_before: "eval(user_input)", fix_after: "literal()"}
               )

      assert result.before == :vulnerable
      assert result.after == :fixed
      assert result.verified_fixed? == true
    end
  end

  describe "apply" do
    test "apply defaults to false and does not write", %{dir: dir} do
      path = Path.join(dir, "app.py")
      File.write!(path, "os.system(cmd)\n")

      checker = checker_seq({:vulnerable, "present"}, {:vulnerable, "present"})

      assert {:ok, _} =
               FixVerify.verify(finding(%{file_path: path}),
                 checker: checker,
                 fix: %{file_path: path, fix_before: "os.system(cmd)", fix_after: "safe()"}
               )

      assert File.read!(path) == "os.system(cmd)\n"
    end

    test "replace happens once even when the needle appears twice", %{dir: dir} do
      path = Path.join(dir, "app.py")
      File.write!(path, "os.system(a)\nos.system(b)\n")

      checker = checker_seq({:vulnerable, "present"}, {:vulnerable, "one remains"})

      assert {:ok, _} =
               FixVerify.verify(finding(%{file_path: path}),
                 checker: checker,
                 apply: true,
                 fix: %{file_path: path, fix_before: "os.system", fix_after: "safe"}
               )

      assert File.read!(path) == "safe(a)\nos.system(b)\n"
    end
  end
end
