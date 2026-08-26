defmodule OptimalSystemAgent.Security.SandboxArtifactsTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.SandboxArtifacts

  setup do
    base = Path.join(System.tmp_dir!(), "osa-sandbox-artifacts-#{System.unique_integer([:positive])}")
    root = Path.join(base, "sandbox")
    dest = Path.join(base, "dest")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, root: root, dest: dest, base: base}
  end

  test "copy poc_1.py from root to dest, sha256 matches", %{root: root, dest: dest} do
    content = "print('poc')\n"
    File.write!(Path.join(root, "poc_1.py"), content)
    expected = sha256(content)

    assert {:ok, %{copied: [item], blocked: []}} =
             SandboxArtifacts.pull(root, ["poc_1.py"], dest: dest)

    assert item.bytes == byte_size(content)
    assert item.sha256 == expected
    assert File.read!(item.path) == content
    assert File.read!(Path.join(dest, "poc_1.py")) == content
  end

  test "../ escape is blocked", %{root: root, dest: dest, base: base} do
    File.write!(Path.join(base, "secret.txt"), "outside\n")

    assert {:ok, %{copied: [], blocked: [blocked]}} =
             SandboxArtifacts.pull(root, ["../secret.txt"], dest: dest)

    assert blocked.path == "../secret.txt"
    assert is_binary(blocked.error)
    assert blocked.error =~ "escape" or blocked.error =~ "root"
    refute File.exists?(Path.join(dest, "secret.txt"))
  end

  test "cookies.txt is refused", %{root: root, dest: dest} do
    File.write!(Path.join(root, "cookies.txt"), "sid=abc\n")

    assert {:ok, %{copied: [], blocked: [blocked]}} =
             SandboxArtifacts.pull(root, ["cookies.txt"], dest: dest)

    assert blocked.path == "cookies.txt"
    assert blocked.error =~ "cookie" or blocked.error =~ "auth" or blocked.error =~ "refused"
    refute File.exists?(Path.join(dest, "cookies.txt"))
  end

  test "storage_state.json is refused", %{root: root, dest: dest} do
    File.write!(Path.join(root, "storage_state.json"), ~s({"cookies":[]}))

    assert {:ok, %{copied: [], blocked: [blocked]}} =
             SandboxArtifacts.pull(root, ["storage_state.json"], dest: dest)

    assert blocked.path == "storage_state.json"
    assert blocked.error =~ "storage" or blocked.error =~ "auth" or blocked.error =~ "refused"
    refute File.exists?(Path.join(dest, "storage_state.json"))
  end

  test "missing file is blocked, others still copy", %{root: root, dest: dest} do
    File.write!(Path.join(root, "poc_1.py"), "print(1)\n")

    assert {:ok, %{copied: [item], blocked: [blocked]}} =
             SandboxArtifacts.pull(root, ["poc_1.py", "missing.png"], dest: dest)

    assert item.sha256 == sha256("print(1)\n")
    assert File.exists?(item.path)
    assert blocked.path == "missing.png"
    assert blocked.error =~ "not found" or blocked.error =~ "missing"
  end

  test "dest is required", %{root: root} do
    File.write!(Path.join(root, "poc_1.py"), "print(1)\n")

    assert {:error, reason} = SandboxArtifacts.pull(root, ["poc_1.py"], [])
    assert is_binary(reason)
    assert reason =~ "dest"
  end

  test "empty paths is an error", %{root: root, dest: dest} do
    assert {:error, reason} = SandboxArtifacts.pull(root, [], dest: dest)
    assert is_binary(reason)
    assert reason =~ "path"
  end

  test "file over max_bytes is blocked", %{root: root, dest: dest} do
    File.write!(Path.join(root, "poc_1.py"), "print('big')\n")

    assert {:ok, %{copied: [], blocked: [blocked]}} =
             SandboxArtifacts.pull(root, ["poc_1.py"], dest: dest, max_bytes: 4)

    assert blocked.path == "poc_1.py"
    assert blocked.error =~ "max_bytes" or blocked.error =~ "too large"
  end

  defp sha256(bin) do
    :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  end
end
