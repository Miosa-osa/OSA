defmodule OptimalSystemAgent.Agent.Safety.PathCanon do
  @moduledoc """
  The single canonicalisation used by every path-based security guard.

  ## Why this module exists

  Six call sites used to "resolve symlinks" like this:

      case :file.read_link_all(String.to_charlist(path)) do
        {:ok, real} -> ...
        {:error, :einval} -> path
      end

  and one of them documented it as "follows the full symlink chain (POSIX
  realpath)". It does not. `read_link_all/1` reads ONE link's *contents* — the
  raw bytes stored in the link — and only when the path's FINAL component is
  itself a symlink. Two independent holes followed:

    * **Intermediate components were never resolved.** Given
      `/allowed/linkdir/secret` where `linkdir -> ~/.ssh`, the leaf is an
      ordinary file, so `read_link_all` returns `{:error, :einval}`, the path
      passes through unchanged, the allowlist and sensitive-path checks see
      `/allowed/…` and approve — and then `File.read` follows the directory
      link anyway. `file_write` was write-capable through the same hole; its
      `resolve_for_write/1` special-cased the immediate parent only, so a
      *grand*parent symlink still escaped.

    * **A relative link target was re-rooted at `/`.** `linkdir -> ../secrets`
      yielded `/../secrets`, a path unrelated to the real target, so the guard
      then evaluated a fabricated path. That happened to fail closed, but a
      security check standing on a fabricated input is not a check.

  `canonicalize/1` does the real thing: expand, then walk the path component by
  component from the root, resolving each symlink (relative targets against the
  link's own directory, absolute targets from the root) under a depth bound, and
  resolving `.`/`..` textually against the already-resolved prefix.

  Unlike `:file.read_link_all/1` and unlike `File.cwd!`-style realpath wrappers,
  this works for paths that **do not exist yet** — the non-existent tail is
  simply appended to the resolved prefix. That is essential for `file_write`,
  whose whole job is creating files.

  Pure apart from `readlink(2)`; never raises.
  """

  # Bound on the number of link hops. Linux's own limit is 40; matching it
  # means we accept every path the kernel would and stop on the ones it would
  # reject with ELOOP.
  @max_hops 40

  @doc """
  The fully symlink-resolved absolute form of `path`.

  Expands `~` and relative paths first, then resolves every component. Returns
  the input expanded (never raises, never returns `nil`) when resolution cannot
  proceed — an unreadable component or a symlink loop leaves the remainder
  untouched, so the caller's allowlist check still runs against a real prefix
  rather than a fabricated one.
  """
  @spec canonicalize(term()) :: String.t()
  def canonicalize(path) when is_binary(path) do
    expanded = Path.expand(path)

    case walk(components(expanded), root_of(expanded), @max_hops) do
      {:ok, resolved} -> resolved
      :error -> expanded
    end
  rescue
    _ -> if is_binary(path), do: path, else: ""
  end

  def canonicalize(_), do: ""

  @doc """
  `{canonical, differs?}` — the canonical path plus whether resolution actually
  moved it. Callers that report "resolves through a symlink" separately from
  "outside the allowlist" want the flag.
  """
  @spec resolve(term()) :: {String.t(), boolean()}
  def resolve(path) when is_binary(path) do
    expanded = Path.expand(path)
    canonical = canonicalize(expanded)
    {canonical, canonical != expanded}
  end

  def resolve(other), do: {canonicalize(other), false}

  # ── Internals ─────────────────────────────────────────────────────────

  # Path.split/1 on an absolute path yields ["/", "a", "b"]; drop the root
  # marker, which `root_of/1` supplies separately.
  defp components(path) do
    case Path.split(path) do
      ["/" | rest] -> rest
      other -> other
    end
  end

  defp root_of(path) do
    case Path.split(path) do
      ["/" | _] -> "/"
      _ -> "."
    end
  end

  # Out of link budget: the path is looping (or pathologically deep). Fail
  # closed by refusing to answer rather than by returning a half-resolved path
  # that could read as "inside the allowlist".
  defp walk(_rest, _acc, hops) when hops <= 0, do: :error

  defp walk([], acc, _hops), do: {:ok, acc}

  defp walk(["." | rest], acc, hops), do: walk(rest, acc, hops)

  defp walk([".." | rest], acc, hops) do
    # `..` is applied to the ALREADY-RESOLVED prefix, which is what the kernel
    # does: after `a/link/..` where `link -> /x/y`, you are in `/x`, not `a`.
    walk(rest, parent(acc), hops)
  end

  defp walk([component | rest], acc, hops) do
    next = join(acc, component)

    case :file.read_link_all(String.to_charlist(next)) do
      {:ok, target} ->
        target = to_string(target)

        if absolute?(target) do
          walk(components(target) ++ rest, "/", hops - 1)
        else
          # A RELATIVE target resolves against the directory holding the link —
          # `acc` — not against the filesystem root.
          walk(components_relative(target) ++ rest, acc, hops - 1)
        end

      _ ->
        # Not a symlink, or does not exist yet. Either way this component is
        # final; keep walking so a later component can still be a link (it
        # cannot be, if this one is missing, but the tail must be preserved).
        walk(rest, next, hops)
    end
  end

  defp components_relative(target), do: Path.split(target)

  defp absolute?(<<"/", _::binary>>), do: true
  defp absolute?(_), do: false

  defp join("/", component), do: "/" <> component
  defp join(acc, component), do: acc <> "/" <> component

  defp parent("/"), do: "/"

  defp parent(acc) do
    case Path.dirname(acc) do
      "" -> "/"
      dir -> dir
    end
  end
end
