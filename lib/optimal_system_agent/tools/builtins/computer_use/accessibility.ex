defmodule OptimalSystemAgent.Tools.Builtins.ComputerUse.Accessibility do
  @moduledoc """
  Accessibility tree parsing, ref assignment, formatting, and diffing.

  Implements ExeVRM-inspired token efficiency:
  - STP (Spatial Token Pruning): only interactive elements get refs
  - TTP (Temporal Token Pruning): diff_trees sends only changes
  """

  @interactive_roles ~w(
    button link textfield textarea checkbox radio menuitem
    menubaritem tab slider combobox popupbutton switch toggle searchfield
    incrementor decrementor disclosure
  )
  @interactive_actions ~w(AXPress AXConfirm AXIncrement AXDecrement AXShowMenu)

  # ── Parse ───────────────────────────────────────────────────────────

  @doc "Normalize raw accessibility data (string or atom keys) into consistent element maps."
  def parse_tree(raw_elements) when is_list(raw_elements) do
    Enum.map(raw_elements, &normalize_element/1)
  end

  defp normalize_element(elem) when is_map(elem) do
    %{
      role: get_field(elem, :role, "unknown"),
      name: get_field(elem, :name, ""),
      value: get_field(elem, :value, ""),
      x: get_field(elem, :x, 0),
      y: get_field(elem, :y, 0),
      width: get_field(elem, :width, 0),
      height: get_field(elem, :height, 0),
      pid: get_field(elem, :pid, nil),
      path: get_field(elem, :path, []),
      identifier: get_field(elem, :identifier, ""),
      actions: get_field(elem, :actions, []),
      enabled: get_field(elem, :enabled, nil),
      focused: get_field(elem, :focused, nil),
      selected: get_field(elem, :selected, nil)
    }
  end

  defp get_field(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  # ── Assign Refs ─────────────────────────────────────────────────────

  @doc """
  Assign sequential refs (e0, e1, ...) to interactive elements.
  Returns {formatted_text, ref_map} where ref_map is %{"e0" => %{x, y, width, height, role, name}, ...}.
  """
  def assign_refs(parsed_elements) do
    {lines, refs, _counter} =
      Enum.reduce(parsed_elements, {[], %{}, 0}, fn elem, {lines, refs, counter} ->
        if interactive?(elem) do
          ref = "e#{counter}"
          line = format_element(ref, elem)

          # Keep the native locator metadata behind the short ref.  Models see
          # `e12`; adapters receive enough identity to re-resolve the element
          # and reject a stale path instead of clicking whatever moved there.
          ref_data = elem

          {[line | lines], Map.put(refs, ref, ref_data), counter + 1}
        else
          line = format_element(nil, elem)
          {[line | lines], refs, counter}
        end
      end)

    text = lines |> Enum.reverse() |> Enum.join("\n")
    {text, refs}
  end

  defp interactive?(elem) do
    elem.role in @interactive_roles or Enum.any?(elem.actions, &(&1 in @interactive_actions))
  end

  defp format_element(ref, elem) do
    prefix = if ref, do: "[#{ref}]", else: "  "
    value = if elem.value in [nil, ""], do: "", else: " value=\"#{truncate(elem.value, 80)}\""

    state =
      [
        if(elem.enabled == false, do: "disabled"),
        if(elem.focused == true, do: "focused"),
        if(elem.selected == true, do: "selected")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(",")

    state = if state == "", do: "", else: " #{state}"

    "#{prefix} #{elem.role} \"#{truncate(elem.name, 120)}\"#{value}#{state} (#{elem.x},#{elem.y}) size=#{elem.width}x#{elem.height}"
  end

  defp truncate(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp truncate(value, _max), do: to_string(value || "")

  # ── Diff Trees (Temporal Token Pruning) ─────────────────────────────

  @doc """
  Compare two ref maps and produce a compact diff string.
  Only changes are included — unchanged elements are omitted.

  Format:
    + [e5] button "New" (300,200)       # appeared
    - [e2] link "Old" (100,50)          # disappeared
    ~ [e1] textfield "Email" moved (200,150) → (200,180)  # changed
  """
  def diff_trees(old_refs, new_refs) when is_map(old_refs) and is_map(new_refs) do
    all_keys =
      MapSet.union(
        MapSet.new(Map.keys(old_refs)),
        MapSet.new(Map.keys(new_refs))
      )

    all_keys
    |> Enum.sort()
    |> Enum.flat_map(fn ref ->
      old = Map.get(old_refs, ref)
      new = Map.get(new_refs, ref)

      cond do
        old == nil and new != nil ->
          ["+ [#{ref}] #{new.role} \"#{new.name}\" (#{new.x},#{new.y})"]

        old != nil and new == nil ->
          ["- [#{ref}] #{old.role} \"#{old.name}\" (#{old.x},#{old.y})"]

        old.x != new.x or old.y != new.y ->
          [
            "~ [#{ref}] #{new.role} \"#{new.name}\" moved (#{old.x},#{old.y}) → (#{new.x},#{new.y})"
          ]

        old.role != new.role or old.name != new.name ->
          [
            "~ [#{ref}] #{old.role} \"#{old.name}\" → #{new.role} \"#{new.name}\" (#{new.x},#{new.y})"
          ]

        true ->
          # unchanged
          []
      end
    end)
    |> Enum.join("\n")
  end
end
