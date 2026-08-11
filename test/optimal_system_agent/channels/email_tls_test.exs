defmodule OptimalSystemAgent.Channels.EmailTlsTest do
  @moduledoc """
  IMAP and SMTP carried `verify: :verify_none`, unconditionally and with no
  config gate.

  That does not weaken the encryption — it removes the reason to trust who is
  on the other end of it. Anything able to intercept the connection can
  present any certificate and read the mailbox password in the `LOGIN` line
  and every message body that follows. `OpenComputers.Session.TlsOpts` in this
  same repo already did it correctly.
  """

  use ExUnit.Case, async: false

  alias OptimalSystemAgent.Channels.EmailChannel

  setup do
    on_exit(fn ->
      for k <- [:email_tls_verify, :email_tls_cacertfile] do
        Application.delete_env(:optimal_system_agent, k)
      end
    end)

    :ok
  end

  describe "by default the peer is verified" do
    test "verify_peer, a real trust store, and a hostname check" do
      opts = EmailChannel.tls_opts(~c"imap.gmail.com")

      assert Keyword.get(opts, :verify) == :verify_peer,
             "mail credentials must not travel over an unauthenticated TLS session"

      assert is_list(Keyword.get(opts, :cacerts)) and Keyword.get(opts, :cacerts) != [],
             "verify_peer without a trust store fails every connection instead of securing it"

      assert Keyword.has_key?(opts, :customize_hostname_check),
             "a valid certificate for the WRONG host is still an interception"
    end

    test "SNI names the host we asked for" do
      opts = EmailChannel.tls_opts(~c"imap.fastmail.com")
      assert Keyword.get(opts, :server_name_indication) == ~c"imap.fastmail.com"
    end

    test "nothing in the default options disables verification" do
      opts = EmailChannel.tls_opts(~c"mail.example.com")
      refute Keyword.get(opts, :verify) == :verify_none
    end
  end

  describe "a private CA is trusted by CONFIGURING it, not by disabling checks" do
    test "cacertfile replaces the bundled store and keeps verify_peer" do
      Application.put_env(:optimal_system_agent, :email_tls_cacertfile, "/etc/ssl/private-ca.pem")

      opts = EmailChannel.tls_opts(~c"mail.internal")

      assert Keyword.get(opts, :verify) == :verify_peer
      assert Keyword.get(opts, :cacertfile) == ~c"/etc/ssl/private-ca.pem"

      refute Keyword.has_key?(opts, :cacerts),
             "the private CA must replace the public store, not sit beside it"
    end
  end

  describe "the escape hatch is explicit and it is gated" do
    test "verification is only disabled when an operator asks for it by name" do
      Application.put_env(:optimal_system_agent, :email_tls_verify, false)

      opts = EmailChannel.tls_opts(~c"mail.example.com")

      assert Keyword.get(opts, :verify) == :verify_none

      # Leaving a trust store or a hostname check alongside :verify_none is
      # worse than removing them: it reads as though something is still being
      # checked.
      refute Keyword.has_key?(opts, :cacerts)
      refute Keyword.has_key?(opts, :cacertfile)
      refute Keyword.has_key?(opts, :customize_hostname_check)
    end

    test "any value other than an explicit false keeps verification on" do
      Application.put_env(:optimal_system_agent, :email_tls_verify, true)
      assert Keyword.get(EmailChannel.tls_opts(~c"h"), :verify) == :verify_peer

      Application.delete_env(:optimal_system_agent, :email_tls_verify)
      assert Keyword.get(EmailChannel.tls_opts(~c"h"), :verify) == :verify_peer
    end
  end
end
