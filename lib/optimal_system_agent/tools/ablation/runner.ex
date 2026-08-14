defmodule OptimalSystemAgent.Tools.Ablation.Runner do
  @moduledoc """
  Toggle one tool-output feature, re-read nine hostile files, report tokens AND
  whether the answer survived.

  ## The method

  Every scenario below runs the REAL tool handlers against the REAL corpus and
  keeps the model-facing result strings — the exact bytes that would enter a
  transcript. Two numbers come out of each run:

    * **tokens** — `Utils.Tokens.estimate/1` over every result string the
      scenario produced. Estimated, not billed: there is no live tokenizer
      binary in this tree, so these are the same numbers OSA's own context
      accounting uses, and they are comparable to each other, which is all a
      delta needs. Bytes are reported alongside precisely so a reader can
      check that the estimator is not doing the work.

    * **probes** — deterministic questions about facts a caller would need,
      each answered ONLY from the result strings. This is the half that makes
      the exercise worth doing.

  ## Why probes are predicates, not a model

  The tempting design is to ask a local model whether the output still answers
  the question. That would make the accuracy column depend on a sampled
  judgement, which is exactly the kind of number we have twice been burned by.

  A probe instead asks something sharper and fully decidable: **is the fact
  still RECOVERABLE from the bytes the tool returned?** If the EOF stamp is
  gone, "did the file end here?" is not recoverable — not unlikely, not
  usually-inferrable, but absent. A model cannot recover information the tool
  did not send, so a predicate over the output is an upper bound on any model's
  accuracy, and an upper bound is the honest thing to report.

  Each probe returns one of three verdicts, and the three are NOT the same:

    * `:ok`     — the fact is present and correct.
    * `:lost`   — the fact is not recoverable. The caller must spend another
                  tool call, or guess.
    * `:wrong`  — the fact is recoverable and WRONG. Strictly worse than
                  `:lost`: a caller that reads it has no signal to distrust it.

  A feature whose removal produces only `:ok` across every probe is fat. A
  feature whose removal produces `:lost` bought something, and the table says
  how much per token.
  """

  alias OptimalSystemAgent.Tools.Ablation
  alias OptimalSystemAgent.Tools.Ablation.Corpus
  alias OptimalSystemAgent.Tools.Builtins.FileEdit.Handler, as: FileEdit
  alias OptimalSystemAgent.Tools.Builtins.FileRead.Handler, as: FileRead
  alias OptimalSystemAgent.Tools.Builtins.FileTransform.Handler, as: FileTransform
  alias OptimalSystemAgent.Tools.UseContext
  alias OptimalSystemAgent.Utils.Tokens

  @doc """
  Run every scenario once per flag state and return the comparison rows.

  `opts`:
    * `:dir`   — corpus directory (default: a fresh temp dir)
    * `:flags` — which flags to ablate (default: all of them)
  """
  @spec run(keyword()) :: %{rows: [map()], scenarios: [map()], transform: map()}
  def run(opts \\ []) do
    dir = Keyword.get(opts, :dir) || default_dir()
    flags = Keyword.get(opts, :flags, Ablation.flags())

    baseline = measure_all(dir, %{})

    rows =
      Enum.map(flags, fn flag ->
        ablated = measure_all(dir, Ablation.ablate(flag))
        compare(flag, baseline, ablated)
      end)

    %{rows: rows, scenarios: baseline, transform: transform_comparison(dir)}
  end

  # ── Measurement ────────────────────────────────────────────────────────

  defp measure_all(dir, overrides) do
    Enum.map(scenarios(), fn scenario ->
      # Fresh corpus per scenario. Several scenarios mutate their file
      # (`growing.log` is appended to, `stable_config.yaml` is edited), and a
      # scenario that inherits the previous one's mutation is measuring the
      # wrong file. Rebuilding is cheap next to being subtly wrong.
      Corpus.build(dir)

      # Fresh session id per measurement, so the read-state cache that drives
      # redundant-read suppression starts empty. Sharing it across the baseline
      # and the ablated run would make the SECOND run suppress reads the first
      # one had already recorded — the ablation would be measuring cache
      # residue rather than the flag.
      ctx = %UseContext{session_id: "ablate-#{scenario.id}-#{unique()}"}

      outputs = Ablation.with_flags(overrides, fn -> scenario.run.(dir, ctx) end)

      text = Enum.map_join(outputs, "\n", &to_text/1)

      %{
        id: scenario.id,
        title: scenario.title,
        tokens: Tokens.estimate(text),
        bytes: byte_size(text),
        probes:
          Enum.map(scenario.probes, fn probe ->
            %{id: probe.id, question: probe.question, verdict: probe.check.(outputs)}
          end)
      }
    end)
  end

  defp compare(flag, baseline, ablated) do
    with_tokens = sum(baseline, :tokens)
    without_tokens = sum(ablated, :tokens)

    # Both directions. A flag whose removal RECOVERS a fact is as much a finding
    # as one whose removal loses one — the per-line clamp is exactly that case,
    # and a table that only counted losses would score it as free.
    moved = fn from_ok? ->
      for b <- baseline,
          a <- ablated,
          a.id == b.id,
          {bp, ap} <- Enum.zip(b.probes, a.probes),
          bp.verdict != ap.verdict,
          (bp.verdict == :ok) == from_ok? do
        %{
          scenario: b.id,
          probe: bp.id,
          question: bp.question,
          was: bp.verdict,
          became: ap.verdict
        }
      end
    end

    regressions = moved.(true)
    improvements = moved.(false)

    %{
      flag: flag,
      # "with" is always the feature PRESENT and "without" always absent,
      # regardless of which of those is production — otherwise `:edit_diff_echo`,
      # whose production state is absent, would read backwards in the table.
      tokens_with: if(production_on?(flag), do: with_tokens, else: without_tokens),
      tokens_without: if(production_on?(flag), do: without_tokens, else: with_tokens),
      bytes_with: if(production_on?(flag), do: sum(baseline, :bytes), else: sum(ablated, :bytes)),
      bytes_without:
        if(production_on?(flag), do: sum(ablated, :bytes), else: sum(baseline, :bytes)),
      production: if(production_on?(flag), do: :on, else: :off),
      regressions: regressions,
      improvements: improvements
    }
  end

  defp production_on?(flag), do: Map.fetch!(Ablation.defaults(), flag)

  defp sum(scenarios, key), do: Enum.reduce(scenarios, 0, &(&2 + Map.fetch!(&1, key)))

  # ── Scenarios ──────────────────────────────────────────────────────────

  @doc "Every scenario, in report order."
  @spec scenarios() :: [map()]
  def scenarios do
    [
      scenario_window_continues(),
      scenario_window_ends_exactly(),
      scenario_whole_small_file(),
      scenario_identical_reread(),
      scenario_tiny_reread(),
      scenario_changed_reread(),
      scenario_minified_line(),
      scenario_mixed_widths(),
      scenario_opaque_base64(),
      scenario_binary_adjacent(),
      scenario_deep_nesting(),
      scenario_exact_edit(),
      scenario_fuzzy_edit()
    ]
  end

  defp scenario_window_continues do
    %{
      id: :window_continues,
      title: "60k-line file, first 100-line window",
      run: fn dir, ctx ->
        [read(dir, "huge_flat.txt", ctx, offset: 1, limit: 100)]
      end,
      probes: [
        %{
          id: :more_to_come,
          question: "Is there more of this file after the window I just read?",
          check: fn out ->
            t = joined(out)

            cond do
              # The continuation stamp names the resume point. Any phrasing that
              # states a NEXT offset satisfies this; the probe is deliberately
              # not matched against one exact sentence, so a wording change in
              # `Messages` does not read as an accuracy regression.
              Regex.match?(~r/(offset|continue|more).{0,80}101\b/is, t) -> :ok
              Regex.match?(~r/\bline 101\b/, t) -> :wrong
              true -> :lost
            end
          end
        },
        %{
          id: :window_fidelity,
          question: "What does line 50 of the file contain?",
          check: fn out ->
            if String.contains?(joined(out), "line 50 |"), do: :ok, else: :lost
          end
        }
      ]
    }
  end

  defp scenario_window_ends_exactly do
    # The decisive stamps case. The window asks for exactly as many lines as the
    # file has, so the returned CONTENT is identical whether or not more exists.
    # Nothing but a stamp can tell the two apart.
    %{
      id: :window_ends_exactly,
      title: "file of exactly 200 lines, read with limit: 200",
      run: fn dir, ctx ->
        [read(dir, "window_exact.txt", ctx, offset: 1, limit: Corpus.exact_window())]
      end,
      probes: [
        %{
          id: :is_this_the_end,
          question: "Did the file end here, or did my window just fill up?",
          check: fn out ->
            t = joined(out)

            cond do
              Regex.match?(~r/end of file|EOF|\bcomplete\b/i, t) -> :ok
              Regex.match?(~r/(offset|continue).{0,80}201\b/is, t) -> :wrong
              true -> :lost
            end
          end
        }
      ]
    }
  end

  defp scenario_whole_small_file do
    %{
      id: :whole_small_file,
      title: "small YAML read whole",
      run: fn dir, ctx -> [read(dir, "stable_config.yaml", ctx, [])] end,
      probes: [
        %{
          id: :have_all_of_it,
          question: "Am I holding the whole file, or a slice the tool chose?",
          check: fn out ->
            if Regex.match?(~r/end of file|EOF|\bcomplete\b/i, joined(out)),
              do: :ok,
              else: :lost
          end
        },
        %{
          id: :content_present,
          question: "What is the value of SENTINEL_CONFIG?",
          check: fn out ->
            if String.contains?(joined(out), "SENTINEL_CONFIG: stable"), do: :ok, else: :lost
          end
        }
      ]
    }
  end

  defp scenario_identical_reread do
    # Deliberately a LARGE window, not the small YAML. Suppression only fires
    # when the bytes it replaces outnumber the ~245-byte notice it costs, so a
    # small file measures the guard rather than the feature — and reports a
    # saving of exactly zero, which reads as "this feature is fat" when it in
    # fact means "this corpus never triggered it". That false negative is the
    # single easiest way for an ablation to mislead, so the case that fires and
    # the case that correctly declines are now separate scenarios.
    %{
      id: :identical_reread,
      title: "same 400-line window read 4x, byte-identical every time",
      run: fn dir, ctx ->
        Enum.map(1..4, fn _ ->
          read(dir, "huge_flat.txt", ctx, offset: 1, limit: 400)
        end)
      end,
      probes: [
        %{
          id: :still_know_content,
          question: "After the 4th read, do I still know what line 50 says?",
          check: fn out ->
            last = out |> List.last() |> to_text()

            cond do
              # Either the content came back again, or the tool said plainly
              # that it is unchanged from the read that DID return content.
              String.contains?(last, "line 50 |") -> :ok
              Regex.match?(~r/unchanged|already read|same as/i, last) -> :ok
              true -> :lost
            end
          end
        }
      ]
    }
  end

  defp scenario_tiny_reread do
    # The other half: a file so small that substituting the notice would GROW
    # the transcript. Suppression must decline, and the ablation must therefore
    # show no saving here — that is the guard working, not the feature failing.
    %{
      id: :tiny_reread,
      title: "150-byte file re-read 4x (notice would cost more than the bytes)",
      run: fn dir, ctx ->
        Enum.map(1..4, fn _ -> read(dir, "stable_config.yaml", ctx, []) end)
      end,
      probes: [
        %{
          id: :no_false_economy,
          question: "Did suppression correctly decline to 'save' by growing the result?",
          check: fn out ->
            last = out |> List.last() |> to_text()

            cond do
              String.contains?(last, "SENTINEL_CONFIG") -> :ok
              Regex.match?(~r/unchanged|already read/i, last) -> :wrong
              true -> :lost
            end
          end
        }
      ]
    }
  end

  defp scenario_changed_reread do
    # The correctness guard on suppression. If a re-read of a file that CHANGED
    # is ever answered with "unchanged", the feature is not saving tokens, it is
    # lying, and this probe returns `:wrong` rather than `:lost`.
    %{
      id: :changed_reread,
      title: "file read, appended to, read again",
      run: fn dir, ctx ->
        first = read(dir, "growing.log", ctx, [])
        Corpus.append(dir, 12)
        second = read(dir, "growing.log", ctx, [])
        [first, second]
      end,
      probes: [
        %{
          id: :sees_the_change,
          question: "Does my second read reflect the 12 appended entries?",
          check: fn out ->
            last = out |> List.last() |> to_text()

            cond do
              String.contains?(last, "appended 12") -> :ok
              Regex.match?(~r/unchanged|already read/i, last) -> :wrong
              true -> :lost
            end
          end
        }
      ]
    }
  end

  defp scenario_minified_line do
    %{
      id: :minified_line,
      title: "single 900 KB minified line",
      run: fn dir, ctx -> [read(dir, "minified.js", ctx, [])] end,
      probes: [
        %{
          id: :truncation_announced,
          question: "Is what I am reading complete, or a fragment?",
          check: fn out ->
            t = joined(out)
            full? = String.contains?(t, "window.SENTINEL_MINIFIED=1")
            announced? = Regex.match?(~r/truncat|clamp|omitted|\.\.\./i, t)

            cond do
              full? -> :ok
              announced? -> :ok
              true -> :wrong
            end
          end
        },
        %{
          id: :tail_reachable,
          question: "What is at the END of the file?",
          check: fn out ->
            if String.contains?(joined(out), "window.SENTINEL_MINIFIED=1"), do: :ok, else: :lost
          end
        }
      ]
    }
  end

  defp scenario_mixed_widths do
    %{
      id: :mixed_widths,
      title: "3 x 50 KB lines hidden among 5,000 normal ones",
      run: fn dir, ctx ->
        [read(dir, "mixed_widths.log", ctx, offset: 995, limit: 12)]
      end,
      probes: [
        %{
          id: :neighbours_intact,
          question: "What do the ordinary lines around the monster line say?",
          check: fn out ->
            t = joined(out)
            if String.contains?(t, "ok 999") and String.contains?(t, "ok 1001"),
              do: :ok,
              else: :lost
          end
        },
        %{
          id: :monster_flagged,
          question: "Was one of these lines too long to return in full?",
          check: fn out ->
            t = joined(out)

            cond do
              Regex.match?(~r/truncat|clamp|omitted/i, t) -> :ok
              String.contains?(t, "END1000") -> :ok
              true -> :wrong
            end
          end
        }
      ]
    }
  end

  defp scenario_opaque_base64 do
    # The counterweight to `minified.js`. Here clamping does not degrade the
    # content, it destroys it: half a base64 blob decodes to nothing. Included
    # so the clamp flag is not scored only on the case that flatters it.
    %{
      id: :opaque_base64,
      title: "three 200 KB base64 lines",
      run: fn dir, ctx -> [read(dir, "base64_blob.txt", ctx, [])] end,
      probes: [
        %{
          id: :blob_usable,
          question: "Can I decode blob1?",
          check: fn out ->
            t = joined(out)

            cond do
              Regex.match?(~r/truncat|clamp|omitted/i, t) -> :lost
              String.contains?(t, "blob1=") -> :ok
              true -> :lost
            end
          end
        },
        %{
          id: :loss_declared,
          question: "If I cannot decode it, was I told why?",
          check: fn out ->
            t = joined(out)

            if Regex.match?(~r/truncat|clamp|omitted/i, t) or String.contains?(t, "blob3="),
              do: :ok,
              else: :wrong
          end
        }
      ]
    }
  end

  defp scenario_binary_adjacent do
    %{
      id: :binary_adjacent,
      title: "clean ASCII head, NULs and invalid UTF-8 further in",
      run: fn dir, ctx -> [read(dir, "binary_adjacent.dat", ctx, [])] end,
      probes: [
        %{
          id: :not_plain_text,
          question: "Is this file safe to reason about as text?",
          check: fn out ->
            t = joined(out)

            if Regex.match?(~r/binary|not valid|non-utf|encoding|convert/i, t),
              do: :ok,
              else: :lost
          end
        }
      ]
    }
  end

  defp scenario_deep_nesting do
    %{
      id: :deep_nesting,
      title: "400-level nested JSON on one line",
      run: fn dir, ctx -> [read(dir, "deep_nest.json", ctx, [])] end,
      probes: [
        %{
          id: :leaf_reachable,
          question: "What is at the bottom of the tree?",
          check: fn out ->
            if String.contains?(joined(out), "LEAF_SENTINEL"), do: :ok, else: :lost
          end
        }
      ]
    }
  end

  defp scenario_exact_edit do
    %{
      id: :exact_edit,
      title: "file_edit with a verbatim old_string",
      run: fn dir, ctx ->
        path = Path.join(dir, "stable_config.yaml")
        _ = read(dir, "stable_config.yaml", ctx, [])

        [
          edit(path, ctx, ~s(SENTINEL_CONFIG: stable), ~s(SENTINEL_CONFIG: edited))
        ]
      end,
      probes: [
        %{
          id: :edit_landed,
          question: "Did my edit land, and did it land where I intended?",
          check: fn out ->
            t = joined(out)
            # On an EXACT match the model already holds both strings from its own
            # request, so a confirmation naming the file is a complete answer.
            if Regex.match?(~r/replaced/i, t), do: :ok, else: :lost
          end
        }
      ]
    }
  end

  defp scenario_fuzzy_edit do
    # The case the exact/fuzzy split exists for. Here `old_string` did NOT
    # appear verbatim, so what changed is genuinely new information and the diff
    # is a correctness signal rather than an echo. Present in the table to show
    # the diff-echo flag does not touch it.
    %{
      id: :fuzzy_edit,
      title: "file_edit whose old_string differs in whitespace",
      run: fn dir, ctx ->
        path = Path.join(dir, "stable_config.yaml")
        _ = read(dir, "stable_config.yaml", ctx, [])

        [edit(path, ctx, "  memory:  2Gi", "  memory: 4Gi")]
      end,
      probes: [
        %{
          id: :fuzzy_shows_change,
          question: "My text did not match verbatim — what did the tool actually change?",
          check: fn out ->
            t = joined(out)

            cond do
              String.contains?(t, "-") and Regex.match?(~r/memory/i, t) -> :ok
              Regex.match?(~r/replaced/i, t) -> :lost
              true -> :lost
            end
          end
        }
      ]
    }
  end

  # ── file_transform vs file_read + file_edit ────────────────────────────

  @doc """
  The same three substitutions, done two ways, priced on what each puts in the
  transcript.

  This is not a flag — there is nothing to toggle. It is a route comparison, and
  it belongs in the same report because it answers the same question: what does
  a choice cost, and does the cheaper route still tell the caller what happened.
  """
  @spec transform_comparison(Path.t()) :: map()
  def transform_comparison(dir) do
    edits = [
      {"service: osa", "service: osa-prime"},
      {"replicas: 3", "replicas: 9"},
      {"      cpu: \"1500m\"", "      cpu: \"3000m\""}
    ]

    # Route A: read the file, then one file_edit per substitution.
    Corpus.build(dir)
    ctx_a = %UseContext{session_id: "ablate-route-a-#{unique()}"}
    path_a = Path.join(dir, "stable_config.yaml")

    route_a =
      [read(dir, "stable_config.yaml", ctx_a, [])] ++
        Enum.map(edits, fn {old, new} -> edit(path_a, ctx_a, old, new) end)

    # Route B: one file_transform carrying all three, anchored.
    Corpus.build(dir)
    ctx_b = %UseContext{session_id: "ablate-route-b-#{unique()}"}
    path_b = Path.join(dir, "stable_config.yaml")

    route_b = [
      transform(
        path_b,
        ctx_b,
        Enum.map(edits, fn {old, new} ->
          %{"op" => "replace", "find" => old, "to" => new, "expect" => 1}
        end)
      )
    ]

    text_a = Enum.map_join(route_a, "\n", &to_text/1)
    text_b = Enum.map_join(route_b, "\n", &to_text/1)

    %{
      route_a: %{calls: length(route_a), tokens: Tokens.estimate(text_a), bytes: byte_size(text_a)},
      route_b: %{calls: length(route_b), tokens: Tokens.estimate(text_b), bytes: byte_size(text_b)},
      # Did the cheaper route still say what happened? `file_transform` reports
      # per-operation counts, which is the fact a caller needs and the thing an
      # unanchored bulk edit cannot provide.
      route_b_reports_counts: Regex.match?(~r/\b3\b|replace/i, text_b)
    }
  end

  # ── Tool invocation ────────────────────────────────────────────────────

  defp read(dir, name, ctx, opts) do
    input =
      %{"path" => Path.join(dir, name)}
      |> maybe_put("offset", Keyword.get(opts, :offset))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    FileRead.execute(input, ctx)
  end

  defp edit(path, ctx, old, new) do
    FileEdit.execute(
      %{"path" => path, "old_string" => old, "new_string" => new},
      ctx
    )
  end

  defp transform(path, ctx, operations) do
    FileTransform.execute(%{"path" => path, "operations" => operations}, ctx)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Result shapes ──────────────────────────────────────────────────────

  # Every file tool returns the model-facing string in the same position, but
  # not in the same tuple: `file_edit` adds a 3-tuple carrying diff metadata for
  # the TUI, and `file_read` can return an image payload. Only the string the
  # model would see is counted — TUI metadata never enters a transcript and
  # must not be billed as if it did.
  defp to_text({:ok, text}) when is_binary(text), do: text
  defp to_text({:ok, text, _meta}) when is_binary(text), do: text
  defp to_text({:error, text}) when is_binary(text), do: text
  defp to_text({:ok, {:image, _}}), do: ""
  defp to_text(other), do: inspect(other)

  defp joined(outputs), do: Enum.map_join(outputs, "\n", &to_text/1)

  defp unique, do: System.unique_integer([:positive])

  defp default_dir,
    do: Path.join(System.tmp_dir!(), "osa-ablation-#{System.unique_integer([:positive])}")
end
