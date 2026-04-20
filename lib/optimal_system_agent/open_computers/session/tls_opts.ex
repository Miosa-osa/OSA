defmodule OptimalSystemAgent.OpenComputers.Session.TlsOpts do
  @moduledoc """
  TLS options for Mint connections to the MIOSA control plane.

  Uses the OTP-bundled CA certs (`:public_key.cacerts_get/0`) and enables
  hostname verification per the public_key pkix match function.
  """

  @spec build() :: keyword()
  def build do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
