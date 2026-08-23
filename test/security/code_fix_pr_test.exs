defmodule OptimalSystemAgent.Security.CodeFixPrTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.CodeFixPr

  setup do
    cwd = Path.join(System.tmp_dir!(), "osa-autofix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)
    {:ok, cwd: cwd}
  end

  defp two_fixes do
    [
      %{
        finding_key: "vuln_sqli",
        file_path: "a.py",
        fix_before: ~s(query = f"SELECT * FROM users WHERE id={id}"),
        fix_after: ~s(query = "SELECT * FROM users WHERE id=?"),
        explanation: "Parameterized query prevents SQL injection."
      },
      %{
        finding_key: "vuln_eval",
        file_path: "b.py",
        fix_before: "eval(user_input)",
        fix_after: "ast.literal_eval(user_input)",
        explanation: "literal_eval does not execute code."
      }
    ]
  end

  defp seed_both!(cwd) do
    File.write!(
      Path.join(cwd, "a.py"),
      ~s(query = f"SELECT * FROM users WHERE id={id}") <> "\n"
    )

    File.write!(Path.join(cwd, "b.py"), "eval(user_input)\n")
  end

  defp capturing_runner do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    runner = fn cmd, opts ->
      Agent.update(agent, fn acc -> acc ++ [{cmd, opts}] end)

      case cmd do
        ["gh", "pr", "create" | _] ->
          {:ok, "Opening...\nhttps://github.com/acme/app/pull/42\n"}

        ["git", "commit" | _] ->
          {:ok, "[osa/autofix-s abcdef1] fix(security): apply OSA autofix\n"}

        ["git", "rev-parse" | _] ->
          {:ok, "abcdef1234567890\n"}

        _ ->
          {:ok, ""}
      end
    end

    {agent, runner}
  end

  defp commands(agent) do
    Agent.get(agent, fn acc -> Enum.map(acc, &elem(&1, 0)) end)
  end

  defp index_of(cmds, pred) do
    Enum.find_index(cmds, pred)
  end

  test "two fixes both apply and runner sees checkout, add, commit, push, gh pr create", %{
    cwd: cwd
  } do
    seed_both!(cwd)
    {agent, runner} = capturing_runner()
    session_id = "sess-1"

    assert {:ok, result} =
             CodeFixPr.open_pr(session_id,
               cwd: cwd,
               fixes: two_fixes(),
               runner: runner
             )

    assert result.applied == ["a.py", "b.py"]
    assert result.skipped == []
    assert result.branch == "osa/autofix-sess-1"
    assert result.url == "https://github.com/acme/app/pull/42"
    assert is_binary(result.sha) or is_nil(result.sha)

    assert File.read!(Path.join(cwd, "a.py")) =~ ~s(query = "SELECT * FROM users WHERE id=?")
    refute File.read!(Path.join(cwd, "a.py")) =~ "id={id}"
    assert File.read!(Path.join(cwd, "b.py")) =~ "ast.literal_eval(user_input)"

    cmds = commands(agent)

    i_co =
      index_of(cmds, fn
        ["git", "checkout", "-b", "osa/autofix-sess-1"] -> true
        ["git", "switch", "-c", "osa/autofix-sess-1"] -> true
        _ -> false
      end)

    i_add = index_of(cmds, &match?(["git", "add" | _], &1))
    i_ci = index_of(cmds, &match?(["git", "commit", "-m" | _], &1))
    i_push = index_of(cmds, &match?(["git", "push", "-u", "origin", "osa/autofix-sess-1"], &1))
    i_gh = index_of(cmds, &match?(["gh", "pr", "create" | _], &1))

    assert i_co != nil
    assert i_add != nil
    assert i_ci != nil
    assert i_push != nil
    assert i_gh != nil
    assert i_co < i_add
    assert i_add < i_ci
    assert i_ci < i_push
    assert i_push < i_gh

    add_cmd = Enum.find(cmds, &match?(["git", "add" | _], &1))
    assert "a.py" in add_cmd
    assert "b.py" in add_cmd

    gh_cmd = Enum.find(cmds, &match?(["gh", "pr", "create" | _], &1))
    assert "--base" in gh_cmd
    assert "main" in gh_cmd
    assert "--title" in gh_cmd
    assert "fix(security): apply OSA autofix" in gh_cmd
    assert "--body" in gh_cmd
  end

  test "returned url is parsed from gh stdout", %{cwd: cwd} do
    seed_both!(cwd)
    {_agent, runner} = capturing_runner()

    assert {:ok, result} =
             CodeFixPr.open_pr("s", cwd: cwd, fixes: two_fixes(), runner: runner)

    assert result.url == "https://github.com/acme/app/pull/42"
  end

  test "one missing fix_before is skipped and the other still opens a PR", %{cwd: cwd} do
    File.write!(
      Path.join(cwd, "a.py"),
      ~s(query = f"SELECT * FROM users WHERE id={id}") <> "\n"
    )

    File.write!(Path.join(cwd, "b.py"), "print('untouched')\n")

    {agent, runner} = capturing_runner()

    assert {:ok, result} =
             CodeFixPr.open_pr("s", cwd: cwd, fixes: two_fixes(), runner: runner)

    assert result.applied == ["a.py"]
    assert result.skipped == ["b.py"]
    assert result.url == "https://github.com/acme/app/pull/42"

    cmds = commands(agent)
    assert Enum.any?(cmds, &match?(["gh", "pr", "create" | _], &1))
    add_cmd = Enum.find(cmds, &match?(["git", "add" | _], &1))
    assert "a.py" in add_cmd
    refute "b.py" in add_cmd
  end

  test "zero applied returns error and does not call gh pr create", %{cwd: cwd} do
    File.write!(Path.join(cwd, "a.py"), "unrelated()\n")
    File.write!(Path.join(cwd, "b.py"), "also_unrelated()\n")

    {agent, runner} = capturing_runner()

    assert {:error, reason} =
             CodeFixPr.open_pr("s", cwd: cwd, fixes: two_fixes(), runner: runner)

    assert is_binary(reason)
    refute reason == ""

    cmds = commands(agent)
    refute Enum.any?(cmds, &match?(["gh", "pr", "create" | _], &1))
    refute Enum.any?(cmds, &match?(["git", "commit" | _], &1))
    refute Enum.any?(cmds, &match?(["git", "push" | _], &1))
  end

  test "missing cwd is an error" do
    {agent, runner} = capturing_runner()

    assert {:error, reason} = CodeFixPr.open_pr("s", fixes: two_fixes(), runner: runner)
    assert reason =~ "cwd"

    cmds = commands(agent)
    assert cmds == []
  end

  test "empty fixes is an error", %{cwd: cwd} do
    {agent, runner} = capturing_runner()

    assert {:error, reason} = CodeFixPr.open_pr("s", cwd: cwd, fixes: [], runner: runner)
    assert is_binary(reason)

    cmds = commands(agent)
    assert cmds == []
    refute Enum.any?(cmds, &match?(["gh", "pr", "create" | _], &1))
  end

  test "render_body includes finding key and Review before merge" do
    body = CodeFixPr.render_body(two_fixes(), "")
    assert body =~ "vuln_sqli"
    assert body =~ "Review before merge"
    assert body =~ "a.py"
    assert body =~ "Parameterized query"
  end
end
