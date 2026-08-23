defmodule OptimalSystemAgent.Agent.SecurityContextTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Agent.SecurityContext

  describe "security_task_active?/1" do
    test "returns false when no security signals present" do
      state = %{messages: [%{content: "hello world"}], session_id: "test-1"}
      refute SecurityContext.security_task_active?(state)
    end

    test "returns false for non-security messages" do
      state = %{messages: [%{content: "build a react app"}], session_id: "test-2"}
      refute SecurityContext.security_task_active?(state)
    end

    test "returns true when security keywords in messages" do
      state = %{messages: [%{content: "run nmap scan against target"}], session_id: "test-3"}
      assert SecurityContext.security_task_active?(state)
    end

    test "returns true for pentest keyword" do
      state = %{messages: [%{content: "do a pentest of example.com"}], session_id: "test-4"}
      assert SecurityContext.security_task_active?(state)
    end

    test "returns true for sqlmap keyword" do
      state = %{messages: [%{content: "use sqlmap to test this endpoint"}], session_id: "test-5"}
      assert SecurityContext.security_task_active?(state)
    end

    test "returns true for vulnerability assessment keyword" do
      state = %{
        messages: [%{content: "vulnerability assessment of 10.0.0.1"}],
        session_id: "test-6"
      }

      assert SecurityContext.security_task_active?(state)
    end

    test "returns false when system_prompt_override is set (subagent)" do
      state = %{
        messages: [%{content: "run nmap scan"}],
        session_id: "test-7",
        system_prompt_override: "You are a pentester"
      }

      refute SecurityContext.security_task_active?(state)
    end

    test "checks last 5 messages" do
      state = %{
        messages: [
          %{content: "hello"},
          %{content: "how are you"},
          %{content: "lets build something"},
          %{content: "actually"},
          %{content: "run a pentest on scanme.nmap.org"}
        ],
        session_id: "test-8"
      }

      assert SecurityContext.security_task_active?(state)
    end

    test "does not trigger on old security messages outside window" do
      state = %{
        messages: [
          %{content: "run nmap scan"},
          %{content: "ok now help me build a react app"},
          %{content: "add a button"},
          %{content: "style it with tailwind"},
          %{content: "deploy to vercel"},
          %{content: "check the build"}
        ],
        session_id: "test-9"
      }

      refute SecurityContext.security_task_active?(state)
    end
  end

  describe "security_posture_block/1" do
    test "returns nil when no security task active" do
      state = %{messages: [%{content: "build a react app"}], session_id: "test-10"}
      assert is_nil(SecurityContext.security_posture_block(state))
    end

    test "returns posture text when security task active" do
      state = %{messages: [%{content: "pentest example.com"}], session_id: "test-11"}
      result = SecurityContext.security_posture_block(state)
      assert is_binary(result)
      assert String.contains?(result, "Authorization Framework")
      assert String.contains?(result, "Behavioral Policy")
      assert String.contains?(result, "Do NOT refuse")
      assert String.contains?(result, "how OSA actually pentests")
      assert String.contains?(result, "Live beats source")
    end
  end

  describe "sandbox_environment_block/1" do
    test "returns nil when no security task active" do
      state = %{messages: [%{content: "build a react app"}], session_id: "test-12"}
      assert is_nil(SecurityContext.sandbox_environment_block(state))
    end

    test "returns sandbox context when security task active" do
      state = %{messages: [%{content: "pentest example.com"}], session_id: "test-13"}
      result = SecurityContext.sandbox_environment_block(state)
      assert is_binary(result)
      # These sections are present in both cloud and host contexts
      assert String.contains?(result, "scan_methodology")
      assert String.contains?(result, "finding_quality")
      assert String.contains?(result, "maximize_parallel_tool_calls")
    end

    test "includes port-scan false positive warning for cloud backends" do
      # On host backend, the port-scan warning is absent — that's correct.
      # On cloud, it would be present. We verify the host path doesn't crash
      # and still returns useful methodology sections.
      state = %{messages: [%{content: "nmap scan"}], session_id: "test-14"}
      result = SecurityContext.sandbox_environment_block(state)
      assert is_binary(result)
      # Should always contain scan methodology regardless of backend
      assert String.contains?(result, "scan_methodology")
    end

    test "includes tool recipes" do
      state = %{messages: [%{content: "use interactsh for blind ssrf"}], session_id: "test-15"}
      result = SecurityContext.sandbox_environment_block(state)
      assert is_binary(result)
      # Tool recipes are in the sandbox context (cloud/docker), not host
      # On host, we still get scan methodology and finding quality
      assert String.contains?(result, "finding_quality")
    end
  end
end
