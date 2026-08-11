defmodule OptimalSystemAgent.Auth.RefreshFailures do
  @moduledoc """
  The one place that decides when a rejected refresh means "sign this account
  out", so every provider decides it the same way.

  ## Why this is shared rather than per-provider

  Deleting a stored credential is the most destructive thing the auth surface
  can do without asking: the user cannot undo it, cannot recover the token,
  and has to walk the whole sign-in flow again — mid-conversation, usually
  without understanding why. That decision was previously spelled three
  different ways for one question:

    * `OpenAICodex` required **two consecutive** `invalid_grant` responses,
      with a comment explaining that providers return it for transient
      reasons and that "a single bad minute signing someone out
      mid-conversation is a worse outcome than one extra failed turn".
    * `Copilot` deleted on the **first** one.
    * `XAI`, `Qwen` and `MiniMax` **never** deleted, so a genuinely revoked
      grant retried its failure on every single message forever.

  Those are three different answers to one question, and only one of them had
  a reason attached. The reasoned one wins, and lives here.

  ## Why the count is per provider, and why it does not survive a restart

  Per provider because a bad minute at GitHub says nothing about OpenAI, and
  a shared counter would let one flaky provider sign the user out of another.

  `:persistent_term` because the count must survive across turns inside one
  OS process — the two rejections that justify a sign-out are usually two
  consecutive messages — but is worthless across a restart. A fresh process
  re-testing a credential once before condemning it is exactly the behaviour
  we want; the alternative is a strike that outlives the outage that caused
  it and signs the user out on their next launch.

  It is also why `reset/1` is called from `logout/0`. Signing out and back in
  within one OS process must start from zero strikes: without that, a fresh
  sign-in inherits the previous credential's strike and the very next
  transient rejection deletes a credential that is seconds old.
  """

  require Logger

  # Two, not one, for the reason in the moduledoc. Not more than two, because
  # a genuinely revoked grant should stop being retried promptly rather than
  # failing every message for the rest of the session.
  @strikes 2

  @doc "How many consecutive rejections it takes to sign an account out."
  @spec strike_limit() :: pos_integer()
  def strike_limit, do: @strikes

  @doc "Consecutive-rejection count for a provider."
  @spec count(String.t() | atom()) :: non_neg_integer()
  def count(provider_id), do: :persistent_term.get(key(provider_id), 0)

  @doc """
  Record one rejection and answer whether it is time to sign out.

  Returns `true` only on the `strike_limit/0`-th consecutive rejection, and
  clears the count when it does — the credential is about to be deleted, so
  the strikes against it are meaningless and must not carry over to whatever
  the user signs in with next.
  """
  @spec record_and_sign_out?(String.t() | atom()) :: boolean()
  def record_and_sign_out?(provider_id) do
    n = count(provider_id) + 1
    :persistent_term.put(key(provider_id), n)

    if n >= @strikes do
      reset(provider_id)
      true
    else
      false
    end
  end

  @doc """
  Forget a provider's consecutive-rejection count.

  Call after any successful token use, and from `logout/0`. Public so tests
  can establish a known starting point: the counter is process-global by
  design and would otherwise leak between tests, which is a good way to make
  a two-strike rule intermittently look like a one-strike rule.
  """
  @spec reset(String.t() | atom()) :: :ok
  def reset(provider_id) do
    :persistent_term.put(key(provider_id), 0)
    :ok
  end

  @doc """
  Apply the rule: log honestly, and delete the credential only on the final
  strike. Returns `true` when the credential was signed out.

  `delete_fun` is passed in rather than calling `SubscriptionStore` directly
  so this module stays a policy with no storage opinion, and so a test can
  observe the decision without a disk.
  """
  @spec handle_rejection(String.t() | atom(), String.t(), (-> any())) :: boolean()
  def handle_rejection(provider_id, display_name, delete_fun) when is_function(delete_fun, 0) do
    if record_and_sign_out?(provider_id) do
      Logger.warning(
        "[Auth] #{display_name} rejected the refresh token #{@strikes} times in a row; " <>
          "signing out locally."
      )

      _ = delete_fun.()
      true
    else
      Logger.warning(
        "[Auth] #{display_name} rejected a token refresh. Keeping the credential — " <>
          "a second consecutive rejection will sign you out."
      )

      false
    end
  end

  defp key(provider_id), do: {__MODULE__, to_string(provider_id)}
end
