defmodule OptimalSystemAgent.Sandbox.DockerTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Sandbox.Docker

  @default_image "python:3.12-slim"
  @default_memory "256m"

  describe "build_run_args/3 — defaults" do
    test "includes --read-only by default" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      assert "--read-only" in args
    end

    test "includes --network none by default" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      assert "--network" in args
      idx = Enum.find_index(args, &(&1 == "--network"))
      assert Enum.at(args, idx + 1) == "none"
    end

    test "includes default pids-limit of 100" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      idx = Enum.find_index(args, &(&1 == "--pids-limit"))
      assert Enum.at(args, idx + 1) == "100"
    end

    test "includes default memory limit" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      idx = Enum.find_index(args, &(&1 == "--memory"))
      assert Enum.at(args, idx + 1) == @default_memory
    end

    test "includes cap-drop ALL" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      assert "--cap-drop" in args
      idx = Enum.find_index(args, &(&1 == "--cap-drop"))
      assert Enum.at(args, idx + 1) == "ALL"
    end

    test "includes tmpfs for /tmp" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      assert "--tmpfs" in args
    end

    test "uses default image" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      assert @default_image in args
    end

    test "appends the command as last args" do
      args = Docker.build_run_args(%{}, [], "nmap -sS 10.0.0.1")
      assert List.last(args) == "nmap -sS 10.0.0.1"
      # sh -c precedes the command
      idx = Enum.find_index(args, &(&1 == "sh"))
      assert Enum.at(args, idx + 1) == "-c"
      assert Enum.at(args, idx + 2) == "nmap -sS 10.0.0.1"
    end
  end

  describe "build_run_args/3 — pentest profile (network + writable)" do
    @pentest_config %{
      image: "osa/pentest:latest",
      memory: "2g",
      network: true,
      read_only: false,
      pids_limit: 500
    }

    test "does NOT include --read-only when read_only: false" do
      args = Docker.build_run_args(@pentest_config, [], "nmap -sS 10.0.0.1")
      refute "--read-only" in args
    end

    test "does NOT include --network none when network: true" do
      args = Docker.build_run_args(@pentest_config, [], "nmap -sS 10.0.0.1")
      refute "--network" in args
      refute "none" in args
    end

    test "uses configured pids_limit" do
      args = Docker.build_run_args(@pentest_config, [], "nmap -sS 10.0.0.1")
      idx = Enum.find_index(args, &(&1 == "--pids-limit"))
      assert Enum.at(args, idx + 1) == "500"
    end

    test "uses configured memory" do
      args = Docker.build_run_args(@pentest_config, [], "nmap -sS 10.0.0.1")
      idx = Enum.find_index(args, &(&1 == "--memory"))
      assert Enum.at(args, idx + 1) == "2g"
    end

    test "uses configured image" do
      args = Docker.build_run_args(@pentest_config, [], "nmap -sS 10.0.0.1")
      assert "osa/pentest:latest" in args
    end
  end

  describe "build_run_args/3 — per-call opts override config" do
    test "per-call image overrides config image" do
      args = Docker.build_run_args(%{image: "config-img"}, [image: "override-img"], "echo hi")
      assert "override-img" in args
      refute "config-img" in args
    end

    test "per-call working_dir adds volume mount" do
      args = Docker.build_run_args(%{}, [working_dir: "/tmp/mywork"], "echo hi")
      assert "-v" in args
      idx = Enum.find_index(args, &(&1 == "-v"))
      assert Enum.at(args, idx + 1) == "/tmp/mywork:/workspace"
      assert "-w" in args
      w_idx = Enum.find_index(args, &(&1 == "-w"))
      assert Enum.at(args, w_idx + 1) == "/workspace"
    end

    test "no working_dir means no volume mount" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      refute "-v" in args
      refute "-w" in args
    end
  end

  describe "build_run_args/3 — partial config" do
    test "network: true but read_only unset still gets --read-only" do
      args = Docker.build_run_args(%{network: true}, [], "echo hi")
      assert "--read-only" in args
      refute "--network" in args
    end

    test "read_only: false but network unset still gets --network none" do
      args = Docker.build_run_args(%{read_only: false}, [], "echo hi")
      refute "--read-only" in args
      assert "--network" in args
    end

    test "pids_limit as integer gets stringified" do
      args = Docker.build_run_args(%{pids_limit: 1000}, [], "echo hi")
      idx = Enum.find_index(args, &(&1 == "--pids-limit"))
      assert Enum.at(args, idx + 1) == "1000"
    end
  end

  describe "regression: config-driven args differ from old hardcoded behavior" do
    @moduledoc """
    These tests define what the OLD hardcoded docker.ex produced (--read-only,
    --pids-limit 100, --network none — always, regardless of config) and assert
    the CURRENT config-driven code produces DIFFERENT output when the config
    says so. If someone reverted docker.ex to the hardcoded version, these
    would fail — proving the test discriminates the fix.
    """

    test "read_only: false produces args WITHOUT --read-only (old code always had it)" do
      args = Docker.build_run_args(%{read_only: false, network: true}, [], "nmap -sS 10.0.0.1")

      refute "--read-only" in args,
             "Expected --read-only to be absent when read_only: false, " <>
               "but it was present — this means the config-driven logic is broken " <>
               "or was reverted to the old hardcoded version"
    end

    test "network: true produces args WITHOUT --network none (old code always had it)" do
      args = Docker.build_run_args(%{read_only: false, network: true}, [], "nmap -sS 10.0.0.1")

      refute "--network" in args,
             "Expected --network to be absent when network: true, " <>
               "but it was present — this means the config-driven logic is broken " <>
               "or was reverted to the old hardcoded version"
    end

    test "pids_limit: 500 produces --pids-limit 500 (old code always used 100)" do
      args = Docker.build_run_args(%{pids_limit: 500}, [], "nmap -sS 10.0.0.1")
      idx = Enum.find_index(args, &(&1 == "--pids-limit"))

      assert Enum.at(args, idx + 1) == "500",
             "Expected --pids-limit 500 when pids_limit: 500, " <>
               "but got #{inspect(Enum.at(args, idx + 1))} — this means the " <>
               "config-driven logic is broken or was reverted to the old hardcoded 100"
    end

    test "default config still produces old-style args (backward compat)" do
      args = Docker.build_run_args(%{}, [], "echo hi")
      assert "--read-only" in args
      assert "--network" in args
      idx = Enum.find_index(args, &(&1 == "--pids-limit"))
      assert Enum.at(args, idx + 1) == "100"
    end
  end
end
