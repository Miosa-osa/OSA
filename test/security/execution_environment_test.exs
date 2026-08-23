defmodule OptimalSystemAgent.Security.ExecutionEnvironmentTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Security.ExecutionEnvironment

  describe "kind/1" do
    test "kind(Host module name string) -> :host" do
      assert ExecutionEnvironment.kind("OptimalSystemAgent.Sandbox.Host") == :host
      assert ExecutionEnvironment.kind(OptimalSystemAgent.Sandbox.Host) == :host
    end

    test "kind(\"e2b\") or %{backend: \"e2b\"} -> :cloud" do
      assert ExecutionEnvironment.kind("e2b") == :cloud
      assert ExecutionEnvironment.kind(%{backend: "e2b"}) == :cloud
    end

    test "kind(%{backend: \"docker\"}) -> :docker" do
      assert ExecutionEnvironment.kind(%{backend: "docker"}) == :docker
    end

    test "classifies sandbox_backend and remaining cloud names" do
      assert ExecutionEnvironment.kind(%{sandbox_backend: :host}) == :host
      assert ExecutionEnvironment.kind(%{sandbox_backend: "Docker"}) == :docker
      assert ExecutionEnvironment.kind(:e2b) == :cloud
      assert ExecutionEnvironment.kind("Lambda") == :cloud
      assert ExecutionEnvironment.kind("MicroVM") == :cloud
      assert ExecutionEnvironment.kind("cloud") == :cloud
      assert ExecutionEnvironment.kind("vercel") == :cloud
      assert ExecutionEnvironment.kind("miosa") == :cloud
      assert ExecutionEnvironment.kind(%{backend: nil}) == :ask
      assert ExecutionEnvironment.kind(%{}) == :ask
    end
  end

  describe "port_scan_trustworthy?/1" do
    test "false for :cloud, true for :host" do
      refute ExecutionEnvironment.port_scan_trustworthy?(:cloud)
      assert ExecutionEnvironment.port_scan_trustworthy?(:host)
    end

    test "true for :docker, false for :ask" do
      assert ExecutionEnvironment.port_scan_trustworthy?(:docker)
      refute ExecutionEnvironment.port_scan_trustworthy?(:ask)
    end
  end

  describe "can_reach_localhost?/1" do
    test "false for :docker, true for :host" do
      refute ExecutionEnvironment.can_reach_localhost?(:docker)
      assert ExecutionEnvironment.can_reach_localhost?(:host)
    end

    test "false for :cloud and :ask" do
      refute ExecutionEnvironment.can_reach_localhost?(:cloud)
      refute ExecutionEnvironment.can_reach_localhost?(:ask)
    end
  end

  describe "prompt/1" do
    test "prompt(:cloud) includes false-positive and cookies" do
      text = ExecutionEnvironment.prompt(:cloud)
      assert text =~ "<execution_environment>"
      assert text =~ "</execution_environment>"
      assert String.contains?(String.downcase(text), "false-positive")
      assert String.contains?(String.downcase(text), "cookies")
    end

    test "prompt(:host) includes real machine" do
      text = ExecutionEnvironment.prompt(:host)
      assert text =~ "<execution_environment>"
      assert String.contains?(String.downcase(text), "real machine")
    end

    test "prompt(:docker) says localhost is the container" do
      text = ExecutionEnvironment.prompt(:docker)
      assert text =~ "<execution_environment>"
      assert String.contains?(String.downcase(text), "localhost")
      assert String.contains?(String.downcase(text), "container")
      assert String.contains?(String.downcase(text), "login_session_put")
    end

    test "prompt(:ask) says no terminal environment and do not invent scans" do
      text = ExecutionEnvironment.prompt(:ask)
      assert text =~ "<execution_environment>"
      assert String.contains?(String.downcase(text), "no terminal")
      assert String.contains?(String.downcase(text), "invent")
    end
  end

  describe "local_machine_access_prompt/1" do
    test "mentions tunnel or host backend" do
      for kind <- [:cloud, :docker, :host, :ask] do
        text = ExecutionEnvironment.local_machine_access_prompt(kind)
        down = String.downcase(text)
        assert text =~ "<local_machine_access>"
        assert String.contains?(down, "tunnel") or String.contains?(down, "host backend")
      end
    end
  end
end
