defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.KeyframeTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ComputerUse.Keyframe

  @test_base_dir "/tmp/osa_keyframe_test_#{System.unique_integer([:positive])}"

  setup do
    File.rm_rf!(@test_base_dir)
    on_exit(fn -> File.rm_rf!(@test_base_dir) end)
    %{base_dir: @test_base_dir}
  end

  # ---------------------------------------------------------------------------
  # Journal initialization
  # ---------------------------------------------------------------------------

  describe "init_journal/2" do
    test "creates session directory and empty journal", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_1", base_dir: dir)
      assert File.dir?(journal_dir)
      assert File.exists?(Path.join(journal_dir, "journal.jsonl"))
    end

    test "returns existing dir if already initialized", %{base_dir: dir} do
      {:ok, d1} = Keyframe.init_journal("sess_2", base_dir: dir)
      {:ok, d2} = Keyframe.init_journal("sess_2", base_dir: dir)
      assert d1 == d2
    end
  end

  # ---------------------------------------------------------------------------
  # Record entry
  # ---------------------------------------------------------------------------

  describe "record_entry/3" do
    test "appends JSONL entry to journal", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_rec", base_dir: dir)

      entry = %{
        step: 1,
        action: "click",
        params: %{"x" => 100, "y" => 200},
        result: "ok"
      }

      :ok = Keyframe.record_entry(journal_dir, entry)

      journal_path = Path.join(journal_dir, "journal.jsonl")
      content = File.read!(journal_path)
      assert content =~ "\"step\":1"
      assert content =~ "\"action\":\"click\""
    end

    test "multiple entries create multiple lines", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_multi", base_dir: dir)

      for i <- 1..3 do
        Keyframe.record_entry(journal_dir, %{step: i, action: "click", params: %{}, result: "ok"})
      end

      lines =
        journal_dir
        |> Path.join("journal.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(lines) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Read journal
  # ---------------------------------------------------------------------------

  describe "read_journal/1" do
    test "parses JSONL entries", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_read", base_dir: dir)

      Keyframe.record_entry(journal_dir, %{step: 1, action: "click", params: %{}, result: "ok"})

      Keyframe.record_entry(journal_dir, %{
        step: 2,
        action: "type",
        params: %{"text" => "hi"},
        result: "ok"
      })

      {:ok, entries} = Keyframe.read_journal(journal_dir)
      assert length(entries) == 2
      assert Enum.at(entries, 0)["step"] == 1
      assert Enum.at(entries, 1)["action"] == "type"
    end

    test "returns empty list for empty journal", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_empty", base_dir: dir)
      {:ok, entries} = Keyframe.read_journal(journal_dir)
      assert entries == []
    end
  end

  # ---------------------------------------------------------------------------
  # Keyframe capture (mock — just writes a dummy file)
  # ---------------------------------------------------------------------------

  describe "save_keyframe/3" do
    test "saves keyframe file with sequential naming", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_kf", base_dir: dir)

      {:ok, path1} = Keyframe.save_keyframe(journal_dir, 1, "fake_png_data_1")
      {:ok, path2} = Keyframe.save_keyframe(journal_dir, 2, "fake_png_data_2")

      assert path1 =~ "keyframe_001.png"
      assert path2 =~ "keyframe_002.png"
      assert File.exists?(path1)
      assert File.read!(path1) == "fake_png_data_1"
    end
  end

  # ---------------------------------------------------------------------------
  # Doom loop detection
  # ---------------------------------------------------------------------------

  describe "detect_doom_loop/1" do
    test "no doom loop with different entries", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_nodoom", base_dir: dir)

      for i <- 1..3 do
        Keyframe.record_entry(journal_dir, %{
          step: i,
          action: "click",
          params: %{"x" => i * 100},
          result: "ok",
          keyframe_hash: "hash_#{i}"
        })
      end

      assert Keyframe.detect_doom_loop(journal_dir) == :ok
    end

    test "detects 3 identical keyframe hashes", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_doom", base_dir: dir)

      for i <- 1..3 do
        Keyframe.record_entry(journal_dir, %{
          step: i,
          action: "click",
          params: %{"x" => 100},
          result: "ok",
          keyframe_hash: "same_hash"
        })
      end

      assert {:doom_loop, 3} = Keyframe.detect_doom_loop(journal_dir)
    end

    test "no doom loop with only 2 identical hashes", %{base_dir: dir} do
      {:ok, journal_dir} = Keyframe.init_journal("sess_2doom", base_dir: dir)

      Keyframe.record_entry(journal_dir, %{
        step: 1,
        action: "click",
        params: %{},
        result: "ok",
        keyframe_hash: "same"
      })

      Keyframe.record_entry(journal_dir, %{
        step: 2,
        action: "click",
        params: %{},
        result: "ok",
        keyframe_hash: "same"
      })

      Keyframe.record_entry(journal_dir, %{
        step: 3,
        action: "click",
        params: %{},
        result: "ok",
        keyframe_hash: "diff"
      })

      assert Keyframe.detect_doom_loop(journal_dir) == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Password field suppression
  # ---------------------------------------------------------------------------

  describe "should_capture?/1" do
    test "returns true for normal elements" do
      refs = %{"e0" => %{role: "button", name: "Save"}}
      assert Keyframe.should_capture?(refs) == true
    end

    test "returns false when password field is present" do
      refs = %{
        "e0" => %{role: "button", name: "Login"},
        "e1" => %{role: "textfield", name: "Password"}
      }

      # textfield named "Password" — skip capture
      assert Keyframe.should_capture?(refs) == false
    end

    test "returns false for password role" do
      refs = %{"e0" => %{role: "password", name: ""}}
      assert Keyframe.should_capture?(refs) == false
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup old journals
  # ---------------------------------------------------------------------------

  describe "cleanup_old_journals/2" do
    test "removes journals older than max age", %{base_dir: dir} do
      old_dir = Path.join(dir, "old_session")
      File.mkdir_p!(old_dir)
      File.write!(Path.join(old_dir, "journal.jsonl"), "")

      # Use max_age_seconds: -1 so everything is considered "old"
      {cleaned, _kept} = Keyframe.cleanup_old_journals(dir, max_age_seconds: -1)

      assert cleaned >= 1
      refute File.dir?(old_dir)
    end
  end
end
