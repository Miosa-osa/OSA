defmodule OptimalSystemAgent.Tools.ConflictScope do
  @moduledoc """
  CROSS-CALL conflict detection: what does this call touch, and does it collide
  with what another call in the same batch touches?

  ## Why a per-call predicate was not enough

  `Tools.Behaviour.concurrency_safe?/2` answers a question about ONE call:
  "is this safe to run alongside others?" That shape cannot express the only
  honest answer some tools have, which is "it depends on the other call".

  `download` said `true` with the comment *"multiple downloads to different
  paths are safe"* — a statement about a PAIR, asserted by a predicate that
  never sees the pair. Two downloads to one path were therefore dispatched
  concurrently: a last-write-wins race in which both calls report success and
  the model is told both files landed. That is the same failure mode as the
  `file_edit`-against-itself race fixed in `05b22c57`, where the silent part
  was the whole problem.

  The two available fixes were to force `download` to `false` — correct, but it
  serialises every download including the disjoint ones the batching exists
  for — or to let a call DECLARE what it touches and compare declarations at
  the one layer that sees the whole batch. This module is the second.

  ## The model

  Each call resolves to a `%ConflictScope{}` with a mode:

    * `:parallel` — touches no comparable resource; conflicts with nothing
      except a `:barrier`.
    * `:scoped`   — touches an enumerable, canonicalised set of paths. Two
      scoped calls conflict iff a write on one side meets a read or a write on
      the other.
    * `:barrier`  — conflicts with EVERYTHING. The fail-closed default: an
      unknown tool, an unresolvable path, a tool whose unsafety is not about
      paths at all (`git`, `config`, `use_tool`, `memory_save`).

  Conflict is symmetric, and reflexive for anything that writes — a call always
  conflicts with a second call to the same target, which is exactly the
  `download`-to-one-path case.

  ## Normalisation is the load-bearing part

  A relative path and an absolute path to one file must not look distinct, and
  symlinks exist. `canonical/2` expands against the SAME root the tool itself
  uses (`download` roots relatives at `~/.osa/workspace`, the file family at the
  process cwd via `Path.expand/1`) and then resolves symlinks along the whole
  ancestor chain. If any of that fails, the call degrades to `:barrier` rather
  than to a comparison it cannot trust: a wrong `:barrier` costs latency, a
  wrong "disjoint" costs a file.

  ## Kill switch

  `config :optimal_system_agent, :cross_call_conflict_detection, false` reverts
  every call to the pure per-call semantics (`true` → `:parallel`, `false` →
  `:barrier`). The mechanism is on by default.
  """

  alias OptimalSystemAgent.Tools.Builtins.Download.Constants, as: DownloadConstants

  defstruct mode: :barrier, reads: nil, writes: nil

  @type mode :: :parallel | :scoped | :barrier
  @type t :: %__MODULE__{mode: mode(), reads: MapSet.t(String.t()), writes: MapSet.t(String.t())}

  # Tools whose ONLY reason to serialise is the file they touch. Each entry
  # names the argument(s) carrying the target and the root a relative path is
  # resolved against — the root must match what the tool's own handler does, or
  # two names for one file would compare as distinct.
  #
  # `:cwd` mirrors `Path.expand/1` (file_write/handler.ex:75,
  # file_edit/handler.ex:69). `:workspace` mirrors `download/handler.ex:124`.
  @writers %{
    "file_write" => {["path", "file_path"], :cwd},
    "file_create" => {["path", "file_path"], :cwd},
    "file_edit" => {["path", "file_path"], :cwd},
    "file_transform" => {["path", "file_path"], :cwd},
    "notebook_edit" => {["path", "notebook_path", "file_path"], :cwd},
    "download" => {["path"], :workspace}
  }

  # Readers only matter because a writer may be batched beside them: a read of
  # a file another call in the same batch is rewriting is a torn read.
  @readers %{
    "file_read" => {["path", "file_path"], :cwd}
  }

  # Multi-target writers — the paths live in a list of edit maps.
  @list_writers %{
    "multi_file_edit" => {"edits", ["path", "file_path"], :cwd}
  }

  @empty MapSet.new()

  @doc """
  The scope of one call.

  `per_call_safe?` is the tool's own `concurrency_safe?/2` answer, which is
  still authoritative in the directions it can express: a tool that says `true`
  and declares no paths is `:parallel`, and a tool that says `false` and is not
  in the path-scoped table stays a `:barrier`. Path declarations only ever
  refine — they never promote a non-path-scoped barrier.
  """
  @spec for_call(String.t() | nil, map(), boolean()) :: t()
  def for_call(tool_name, input, per_call_safe?) do
    if enabled?() do
      classify(tool_name, input, per_call_safe?)
    else
      %__MODULE__{mode: if(per_call_safe?, do: :parallel, else: :barrier)}
    end
  rescue
    _ -> %__MODULE__{mode: :barrier}
  catch
    _, _ -> %__MODULE__{mode: :barrier}
  end

  @doc """
  Do these two calls conflict — i.e. must they NOT run at the same time?

  A `:barrier` conflicts with everything (including another barrier).
  Two `:scoped` calls conflict iff one's writes meet the other's reads or
  writes. `:parallel` conflicts with nothing but a barrier.
  """
  @spec conflict?(t(), t()) :: boolean()
  def conflict?(%__MODULE__{mode: :barrier}, %__MODULE__{}), do: true
  def conflict?(%__MODULE__{}, %__MODULE__{mode: :barrier}), do: true
  def conflict?(%__MODULE__{mode: :parallel}, %__MODULE__{}), do: false
  def conflict?(%__MODULE__{}, %__MODULE__{mode: :parallel}), do: false

  def conflict?(%__MODULE__{} = a, %__MODULE__{} = b) do
    not disjoint?(a.writes, b.writes) or
      not disjoint?(a.writes, b.reads) or
      not disjoint?(a.reads, b.writes)
  end

  def conflict?(_, _), do: true

  @doc """
  Does `scope` conflict with ANY scope in `others`? Used by both dispatch sites.
  """
  @spec conflicts_any?(t(), [t()]) :: boolean()
  def conflicts_any?(%__MODULE__{} = scope, others) when is_list(others),
    do: Enum.any?(others, &conflict?(scope, &1))

  @doc """
  A short human-readable reason for a serialisation, for logs and telemetry.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{mode: :barrier}), do: "not concurrency-safe"

  def describe(%__MODULE__{mode: :scoped, writes: w}) do
    case MapSet.to_list(w || @empty) do
      [] -> "path-scoped"
      paths -> "writes #{Enum.join(paths, ", ")}"
    end
  end

  def describe(%__MODULE__{mode: :parallel}), do: "parallel-safe"
  def describe(_), do: "unknown"

  @doc "Whether cross-call conflict detection is active (default: true)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:optimal_system_agent, :cross_call_conflict_detection, true) != false
  end

  # ── Classification ────────────────────────────────────────────────────

  defp classify(name, input, per_call_safe?) when is_binary(name) and is_map(input) do
    cond do
      spec = Map.get(@writers, name) -> scoped_writer(spec, input, name)
      spec = Map.get(@list_writers, name) -> scoped_list_writer(spec, input, name)
      spec = Map.get(@readers, name) -> scoped_reader(spec, input, per_call_safe?)
      per_call_safe? -> %__MODULE__{mode: :parallel}
      true -> %__MODULE__{mode: :barrier}
    end
  end

  defp classify(_, _, per_call_safe?),
    do: %__MODULE__{mode: if(per_call_safe?, do: :parallel, else: :barrier)}

  defp scoped_writer({keys, root}, input, _name) do
    case first_path(input, keys) do
      nil -> %__MODULE__{mode: :barrier}
      raw -> scope_from_paths([raw], root, :write)
    end
  end

  defp scoped_list_writer({list_key, keys, root}, input, _name) do
    case Map.get(input, list_key) do
      list when is_list(list) and list != [] ->
        raws = Enum.map(list, fn e -> if is_map(e), do: first_path(e, keys) end)

        if Enum.any?(raws, &is_nil/1),
          do: %__MODULE__{mode: :barrier},
          else: scope_from_paths(raws, root, :write)

      _ ->
        %__MODULE__{mode: :barrier}
    end
  end

  # A reader whose tool already declared itself per-call safe becomes `:scoped`
  # so a writer batched beside it can be detected. A reader that declared itself
  # UNSAFE keeps that answer — the declaration is about more than its path.
  defp scoped_reader(_spec, _input, false), do: %__MODULE__{mode: :barrier}

  defp scoped_reader({keys, root}, input, true) do
    case first_path(input, keys) do
      # A read with no resolvable path is not a hazard to anyone; it just
      # cannot be compared. Keep the tool's own `true`.
      nil -> %__MODULE__{mode: :parallel}
      raw -> scope_from_paths([raw], root, :read)
    end
  end

  defp scope_from_paths(raws, root, kind) do
    canon = Enum.map(raws, &canonical(&1, root))

    if Enum.any?(canon, &is_nil/1) do
      %__MODULE__{mode: :barrier}
    else
      set = MapSet.new(canon)

      case kind do
        :write -> %__MODULE__{mode: :scoped, writes: set, reads: @empty}
        :read -> %__MODULE__{mode: :scoped, writes: @empty, reads: set}
      end
    end
  end

  defp first_path(input, keys) when is_map(input) do
    Enum.find_value(keys, fn k ->
      case Map.get(input, k) || Map.get(input, safe_atom(k)) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  end

  defp first_path(_, _), do: nil

  # Tool arguments arrive as string keys; the atom lookup is a courtesy for
  # internal callers. `to_existing_atom` so a malformed key cannot grow the
  # atom table.
  defp safe_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> nil
  end

  # ── Normalisation ─────────────────────────────────────────────────────

  @doc """
  Canonicalise one declared target: expand against the tool's own root, then
  resolve symlinks along the ancestor chain. `nil` when it cannot be resolved,
  which callers must treat as `:barrier`.
  """
  @spec canonical(String.t(), :cwd | :workspace) :: String.t() | nil
  def canonical(path, root) when is_binary(path) do
    path
    |> expand_for(root)
    |> realpath(16)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def canonical(_, _), do: nil

  defp expand_for(path, :workspace) do
    if relative?(path),
      do: Path.expand(Path.join(DownloadConstants.workspace_root(), path)),
      else: Path.expand(path)
  end

  defp expand_for(path, _), do: Path.expand(path)

  defp relative?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end

  # Resolve every symlink from the root down, so `/tmp/link/f.txt` and
  # `/real/dir/f.txt` compare equal. Bounded by `fuel` so a symlink cycle
  # returns a path rather than spinning.
  defp realpath(path, 0), do: path

  defp realpath(path, fuel) do
    dir = Path.dirname(path)

    if dir == path do
      path
    else
      joined = Path.join(realpath(dir, fuel - 1), Path.basename(path))

      case :file.read_link(joined) do
        {:ok, target} ->
          target = IO.chardata_to_string(target)

          next =
            if Path.type(target) == :absolute,
              do: target,
              else: Path.expand(Path.join(Path.dirname(joined), target))

          realpath(next, fuel - 1)

        _ ->
          joined
      end
    end
  end

  defp disjoint?(nil, _), do: true
  defp disjoint?(_, nil), do: true
  defp disjoint?(a, b), do: MapSet.disjoint?(a, b)
end
