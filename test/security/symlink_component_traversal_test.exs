defmodule OptimalSystemAgent.Security.SymlinkComponentTraversalTest do
  @moduledoc """
  The file tools guarded against symlink traversal with `:file.read_link_all/1`,
  which reads a link's *contents* — it is NOT realpath. Only the FINAL path
  component was ever considered, so an intermediate directory symlink escaped
  every allowlist and sensitive-path deny:

      /tmp/sandbox/linkdir -> ~/.ssh
      read /tmp/sandbox/linkdir/id_rsa

  `linkdir/id_rsa` is not itself a symlink, so `read_link_all` returns
  `{:error, :einval}`, the guard evaluates `/tmp/sandbox/…`, and `File.read`
  then happily follows the directory link.

  `file_write` was worse still: `resolve_for_write/1` looked at the immediate
  parent only, so a *grand*parent symlink escaped.
  """
  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Agent.Safety.PathCanon
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileReadHandler
  alias OptimalSystemAgent.Tools.Builtins.FileWrite.Handler, as: FileWriteHandler
  alias OptimalSystemAgent.Tools.UseContext

  setup do
    root =
      System.tmp_dir!()
      |> PathCanon.canonicalize()
      |> Path.join("osa-symlink-#{System.unique_integer([:positive])}")

    sandbox = Path.join(root, "sandbox")
    secret_home = Path.join(root, "home")
    ssh = Path.join(secret_home, ".ssh")

    File.mkdir_p!(Path.join(sandbox, "a/b"))
    File.mkdir_p!(ssh)
    File.write!(Path.join(ssh, "id_rsa"), "PRIVATE KEY")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, sandbox: sandbox, ssh: ssh}
  end

  defp ctx, do: %UseContext{}

  describe "PathCanon.canonicalize/1" do
    test "resolves an intermediate directory symlink, not just the last component",
         %{sandbox: sandbox, ssh: ssh} do
      File.ln_s!(ssh, Path.join(sandbox, "linkdir"))

      assert PathCanon.canonicalize(Path.join(sandbox, "linkdir/id_rsa")) ==
               Path.join(ssh, "id_rsa")
    end

    test "resolves a grandparent symlink for a not-yet-existing leaf",
         %{sandbox: sandbox, ssh: ssh} do
      File.ln_s!(ssh, Path.join(sandbox, "linkdir"))

      assert PathCanon.canonicalize(Path.join(sandbox, "linkdir/sub/new.txt")) ==
               Path.join(ssh, "sub/new.txt")
    end

    test "a RELATIVE link target resolves against the link's directory, not /",
         %{sandbox: sandbox} do
      File.write!(Path.join(sandbox, "a/target.txt"), "x")
      File.ln_s!("a/target.txt", Path.join(sandbox, "rel"))

      assert PathCanon.canonicalize(Path.join(sandbox, "rel")) ==
               Path.join(sandbox, "a/target.txt")
    end

    test "a symlink loop terminates and does not raise", %{sandbox: sandbox} do
      File.ln_s!(Path.join(sandbox, "loop_b"), Path.join(sandbox, "loop_a"))
      File.ln_s!(Path.join(sandbox, "loop_a"), Path.join(sandbox, "loop_b"))

      assert is_binary(PathCanon.canonicalize(Path.join(sandbox, "loop_a")))
    end

    test "an ordinary path is returned unchanged", %{sandbox: sandbox} do
      plain = Path.join(sandbox, "a/b")
      assert PathCanon.canonicalize(plain) == plain
    end
  end

  describe "file_read" do
    setup %{sandbox: sandbox, ssh: ssh} do
      File.ln_s!(ssh, Path.join(sandbox, "linkdir"))

      prior = Application.get_env(:optimal_system_agent, :allowed_read_paths)
      Application.put_env(:optimal_system_agent, :allowed_read_paths, [sandbox])

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:optimal_system_agent, :allowed_read_paths)
          p -> Application.put_env(:optimal_system_agent, :allowed_read_paths, p)
        end
      end)

      :ok
    end

    test "a read through a directory symlink out of the allowlist is refused",
         %{sandbox: sandbox} do
      path = Path.join(sandbox, "linkdir/id_rsa")

      assert {:deny, msg} = FileReadHandler.check_permissions(%{"path" => path}, ctx())
      assert msg =~ "Access denied"
    end

    test "a read inside the allowlist still works", %{sandbox: sandbox} do
      File.write!(Path.join(sandbox, "a/ok.txt"), "hello")
      path = Path.join(sandbox, "a/ok.txt")

      assert {:allow, _} = FileReadHandler.check_permissions(%{"path" => path}, ctx())
    end
  end

  describe "file_write" do
    setup %{sandbox: sandbox, ssh: ssh} do
      # sandbox/deep -> ssh ; target is sandbox/deep/sub/x — a GRANDPARENT link.
      File.mkdir_p!(Path.join(ssh, "sub"))
      File.ln_s!(ssh, Path.join(sandbox, "deep"))

      prior = Application.get_env(:optimal_system_agent, :allowed_write_paths)
      Application.put_env(:optimal_system_agent, :allowed_write_paths, [sandbox])

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:optimal_system_agent, :allowed_write_paths)
          p -> Application.put_env(:optimal_system_agent, :allowed_write_paths, p)
        end
      end)

      :ok
    end

    test "a write through a grandparent symlink out of the allowlist is refused",
         %{sandbox: sandbox} do
      path = Path.join(sandbox, "deep/sub/pwned.txt")

      assert {:deny, msg} =
               FileWriteHandler.check_permissions(
                 %{"path" => path, "content" => "x"},
                 ctx()
               )

      assert msg =~ "Access denied"
    end

    test "execute/2 refuses it too (defense in depth) and writes nothing",
         %{sandbox: sandbox, ssh: ssh} do
      path = Path.join(sandbox, "deep/sub/pwned.txt")

      assert {:error, msg} =
               FileWriteHandler.execute(%{"path" => path, "content" => "x"}, ctx())

      assert msg =~ "Access denied"
      refute File.exists?(Path.join(ssh, "sub/pwned.txt"))
    end

    test "a write inside the allowlist still works", %{sandbox: sandbox} do
      path = Path.join(sandbox, "a/new.txt")

      assert {:allow, _} =
               FileWriteHandler.check_permissions(
                 %{"path" => path, "content" => "x"},
                 ctx()
               )
    end
  end
end
