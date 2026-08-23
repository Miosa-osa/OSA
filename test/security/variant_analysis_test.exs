defmodule OptimalSystemAgent.Security.VariantAnalysisTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.VariantAnalysis

  setup do
    root = Path.join(System.tmp_dir!(), "osa-var-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "app"))
    File.write!(Path.join(root, "app/bad.py"), "def f(x):\n    os.system(user_input)\n")
    File.write!(Path.join(root, "app/ok.py"), "def f(x):\n    return x\n")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "needle from a snippet finds the sink and not the clean file", %{root: root} do
    assert {:ok, hits} = VariantAnalysis.scan(root: root, needle: "os.system(cmd)")
    assert Enum.any?(hits, &(&1.path =~ "bad.py"))
    refute Enum.any?(hits, &(&1.path =~ "ok.py"))
    assert hd(Enum.filter(hits, &(&1.path =~ "bad.py"))).fingerprint == "os.system"
  end

  test "literal pattern and max_hits", %{root: root} do
    assert {:ok, hits} = VariantAnalysis.scan(root: root, pattern: "os.system", max_hits: 1)
    assert length(hits) == 1
  end

  test "missing root is an error" do
    assert {:error, _} = VariantAnalysis.scan(root: "/no/such/osa-root")
  end

  test "from_cve_description extracts sink names" do
    fps = VariantAnalysis.from_cve_description("RCE via eval() of user JSON")
    assert "eval(" in fps
  end
end
