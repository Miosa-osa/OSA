defmodule OptimalSystemAgent.OpenComputers.Executor.Direct.FsTest do
  @moduledoc """
  Unit tests for the OSA-side FS executor.
  """

  use ExUnit.Case, async: true

  alias OptimalSystemAgent.OpenComputers.Executor.Direct.Fs

  @max_bytes 4 * 1024 * 1024

  setup do
    tmpdir = System.tmp_dir!() |> Path.join("osa_fs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmpdir)

    Application.put_env(:optimal_system_agent, :oc_fs_allowed_roots, [tmpdir])

    on_exit(fn ->
      Application.delete_env(:optimal_system_agent, :oc_fs_allowed_roots)
      File.rm_rf(tmpdir)
    end)

    {:ok, tmpdir: tmpdir}
  end

  defp req_id, do: "req-#{System.unique_integer([:positive])}"

  describe "list/2" do
    test "lists files and directories", %{tmpdir: dir} do
      File.write!(Path.join(dir, "file.txt"), "hello")
      File.mkdir_p!(Path.join(dir, "subdir"))

      rid = req_id()

      assert {:fs_list_response, %{req_id: ^rid, entries: entries}} =
               Fs.list(rid, %{path: dir})

      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert names == ["file.txt", "subdir"]

      file_entry = Enum.find(entries, &(&1.name == "file.txt"))
      assert file_entry.type == :file
      assert file_entry.size == 5
      assert file_entry.mtime > 0

      dir_entry = Enum.find(entries, &(&1.name == "subdir"))
      assert dir_entry.type == :dir
    end

    test "returns empty entries for empty directory", %{tmpdir: dir} do
      rid = req_id()
      assert {:fs_list_response, %{req_id: ^rid, entries: []}} = Fs.list(rid, %{path: dir})
    end

    test "returns :not_found for non-existent directory", %{tmpdir: dir} do
      rid = req_id()
      missing = Path.join(dir, "nonexistent")

      assert {:fs_error, %{req_id: ^rid, reason: :not_found}} =
               Fs.list(rid, %{path: missing})
    end

    test "returns :path_not_allowed for path outside allowed roots" do
      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :path_not_allowed}} =
               Fs.list(rid, %{path: "/etc"})
    end

    test "blocks directory traversal via ..", %{tmpdir: dir} do
      rid = req_id()
      escape = Path.join([dir, "..", "..", "etc"])

      assert {:fs_error, %{req_id: ^rid, reason: :path_not_allowed}} =
               Fs.list(rid, %{path: escape})
    end
  end

  describe "stat/2" do
    test "stats an existing file", %{tmpdir: dir} do
      path = Path.join(dir, "stat_test.txt")
      File.write!(path, "some content")

      rid = req_id()
      assert {:fs_stat_response, %{req_id: ^rid, stat: stat}} = Fs.stat(rid, %{path: path})
      assert stat.type == :file
      assert stat.size == 12
      assert stat.exists == true
      assert stat.mtime > 0
    end

    test "stats an existing directory", %{tmpdir: dir} do
      rid = req_id()
      assert {:fs_stat_response, %{req_id: ^rid, stat: stat}} = Fs.stat(rid, %{path: dir})
      assert stat.type == :dir
      assert stat.exists == true
    end

    test "returns exists: false for non-existent path", %{tmpdir: dir} do
      rid = req_id()
      missing = Path.join(dir, "missing.txt")

      assert {:fs_stat_response, %{req_id: ^rid, stat: %{exists: false}}} =
               Fs.stat(rid, %{path: missing})
    end

    test "returns :path_not_allowed for path outside roots" do
      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :path_not_allowed}} =
               Fs.stat(rid, %{path: "/etc/passwd"})
    end
  end

  describe "read/2" do
    test "reads a small file completely", %{tmpdir: dir} do
      path = Path.join(dir, "small.txt")
      File.write!(path, "hello world")

      rid = req_id()

      assert {:fs_read_response, %{req_id: ^rid, data: "hello world", eof: true}} =
               Fs.read(rid, %{path: path, offset: 0, max_bytes: 4096})
    end

    test "reads from an offset", %{tmpdir: dir} do
      path = Path.join(dir, "offset.txt")
      File.write!(path, "hello world")

      rid = req_id()

      assert {:fs_read_response, %{req_id: ^rid, data: "world", eof: true}} =
               Fs.read(rid, %{path: path, offset: 6, max_bytes: 4096})
    end

    test "eof is false when more data follows", %{tmpdir: dir} do
      path = Path.join(dir, "multi.txt")
      File.write!(path, "0123456789")

      rid = req_id()

      assert {:fs_read_response, %{req_id: ^rid, data: "01234", eof: false}} =
               Fs.read(rid, %{path: path, offset: 0, max_bytes: 5})
    end

    test "returns :not_found for missing file", %{tmpdir: dir} do
      rid = req_id()
      missing = Path.join(dir, "nope.txt")

      assert {:fs_error, %{req_id: ^rid, reason: :not_found}} =
               Fs.read(rid, %{path: missing, offset: 0, max_bytes: 1024})
    end

    test "returns :too_large when max_bytes > 4 MiB", %{tmpdir: dir} do
      path = Path.join(dir, "file.txt")
      File.write!(path, "x")

      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :too_large}} =
               Fs.read(rid, %{path: path, offset: 0, max_bytes: @max_bytes + 1})
    end

    test "returns :path_not_allowed for path outside roots" do
      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :path_not_allowed}} =
               Fs.read(rid, %{path: "/etc/passwd", offset: 0, max_bytes: 1024})
    end
  end

  describe "write/2" do
    test "creates a new file and writes content", %{tmpdir: dir} do
      path = Path.join(dir, "new_file.txt")

      rid = req_id()

      assert {:fs_write_response, %{req_id: ^rid, bytes_written: 5}} =
               Fs.write(rid, %{
                 path: path,
                 offset: 0,
                 data: "hello",
                 create: true,
                 truncate: true,
                 mode: nil
               })

      assert File.read!(path) == "hello"
    end

    test "write + re-read roundtrip", %{tmpdir: dir} do
      path = Path.join(dir, "roundtrip.txt")
      content = "the quick brown fox"

      w_rid = req_id()

      assert {:fs_write_response, %{bytes_written: bytes}} =
               Fs.write(w_rid, %{
                 path: path,
                 offset: 0,
                 data: content,
                 create: true,
                 truncate: true,
                 mode: nil
               })

      assert bytes == byte_size(content)

      r_rid = req_id()

      assert {:fs_read_response, %{data: ^content, eof: true}} =
               Fs.read(r_rid, %{path: path, offset: 0, max_bytes: 4096})
    end

    test "returns :too_large when data > 4 MiB", %{tmpdir: dir} do
      path = Path.join(dir, "huge.bin")
      big = :binary.copy(<<0>>, @max_bytes + 1)
      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :too_large}} =
               Fs.write(rid, %{
                 path: path,
                 offset: 0,
                 data: big,
                 create: true,
                 truncate: true,
                 mode: nil
               })
    end

    test "returns :path_not_allowed for path outside roots" do
      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :path_not_allowed}} =
               Fs.write(rid, %{
                 path: "/tmp/escape.txt",
                 offset: 0,
                 data: "x",
                 create: true,
                 truncate: true,
                 mode: nil
               })
    end
  end

  describe "delete/2" do
    test "deletes a file", %{tmpdir: dir} do
      path = Path.join(dir, "to_delete.txt")
      File.write!(path, "bye")

      rid = req_id()

      assert {:fs_delete_response, %{req_id: ^rid, ok: true}} =
               Fs.delete(rid, %{path: path, recursive: false})

      refute File.exists?(path)
    end

    test "deletes a directory recursively", %{tmpdir: dir} do
      sub = Path.join(dir, "subdir_to_delete")
      File.mkdir_p!(sub)
      File.write!(Path.join(sub, "nested.txt"), "data")

      rid = req_id()

      assert {:fs_delete_response, %{req_id: ^rid, ok: true}} =
               Fs.delete(rid, %{path: sub, recursive: true})

      refute File.exists?(sub)
    end

    test "returns :not_found for missing path", %{tmpdir: dir} do
      rid = req_id()
      missing = Path.join(dir, "ghost.txt")

      assert {:fs_error, %{req_id: ^rid, reason: :not_found}} =
               Fs.delete(rid, %{path: missing, recursive: false})
    end

    test "returns :path_not_allowed for path outside roots" do
      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :path_not_allowed}} =
               Fs.delete(rid, %{path: "/tmp/system_file", recursive: false})
    end
  end

  describe "mkdir/2" do
    test "creates a directory", %{tmpdir: dir} do
      new_dir = Path.join(dir, "new_dir")

      rid = req_id()

      assert {:fs_mkdir_response, %{req_id: ^rid, ok: true}} =
               Fs.mkdir(rid, %{path: new_dir, recursive: false})

      assert File.dir?(new_dir)
    end

    test "creates nested directories with recursive: true", %{tmpdir: dir} do
      nested = Path.join([dir, "a", "b", "c"])

      rid = req_id()

      assert {:fs_mkdir_response, %{req_id: ^rid, ok: true}} =
               Fs.mkdir(rid, %{path: nested, recursive: true})

      assert File.dir?(nested)
    end

    test "does not error when directory already exists", %{tmpdir: dir} do
      rid = req_id()
      assert {:fs_mkdir_response, %{ok: true}} = Fs.mkdir(rid, %{path: dir, recursive: true})
    end

    test "returns :path_not_allowed for path outside roots" do
      rid = req_id()

      assert {:fs_error, %{req_id: ^rid, reason: :path_not_allowed}} =
               Fs.mkdir(rid, %{path: "/usr/local/osa_test", recursive: false})
    end
  end
end
