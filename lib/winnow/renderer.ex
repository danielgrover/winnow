defmodule Winnow.Renderer do
  @moduledoc """
  Renders a Winnow prompt into a `RenderResult`.

  Implements the priority-based binary search threshold algorithm
  inspired by Priompt/Cursor. The pipeline:

  1. Evaluate conditions
  2. Compute token counts for all pieces
  3. Resolve sections within their own sub-budgets
  4. Binary search for the lowest threshold where the pieces at or above it
     fit the budget in their cheapest form (smallest fallback, or truncated
     down to message overhead)
  5. Greedy pass in priority order: each piece takes its primary, a
     fallback, or a truncation — whatever fits after setting aside the
     minimum cost of every lower-priority piece still pending
  6. Sort by sequence, build messages, populate RenderResult

  Because of step 5's reservation, every piece above the threshold is
  included — except a truncatable piece left with no room for any content,
  which is reported as dropped. `Winnow.OversizedContentError` can only
  occur when `:infinity`-priority pieces alone exceed the budget.
  """

  alias Winnow.ContentPiece
  alias Winnow.RenderResult

  @doc """
  Renders the accumulated prompt pieces within the token budget.
  """
  @spec render(Winnow.t()) :: RenderResult.t()
  def render(%Winnow{} = winnow) do
    tokenizer = winnow.tokenizer
    budget = winnow.budget

    # Step 1: Evaluate conditions — exclude pieces where condition returns false
    {pieces, condition_excluded} = evaluate_conditions(winnow.pieces)

    # Step 2: Compute token costs for each piece (primary and fallbacks)
    costed_pieces = compute_token_costs(pieces, tokenizer)

    # Step 3: Render sections independently within their sub-budgets
    {main_pieces, section_dropped, section_fallbacks} =
      render_sections(costed_pieces, winnow.sections, tokenizer)

    # Step 4: Find the threshold using minimum possible cost
    threshold = find_threshold(main_pieces, budget, tokenizer)

    # Split into included/dropped by threshold
    {above_threshold, dropped} = split_at_threshold(main_pieces, threshold)

    # Step 5: Resolve fallbacks and overflow for pieces above threshold
    {final_included, extra_dropped, fallbacks_used} =
      resolve_fit(above_threshold, budget, tokenizer)

    main_dropped = dropped ++ extra_dropped
    all_dropped = main_dropped ++ section_dropped

    # A section piece that resolved to a fallback may still be dropped by
    # the main pass; only report fallbacks whose result was kept.
    all_fallbacks =
      (section_fallbacks ++ fallbacks_used)
      |> Enum.reject(fn {_original, _index, resolved} -> resolved in main_dropped end)
      |> Enum.map(fn {original, index, _resolved} -> {original, index} end)

    # Sort included by sequence for output ordering
    final_included = Enum.sort_by(final_included, & &1.sequence)

    # Filter out empty-content pieces (reservations) for messages and cache
    message_pieces = Enum.reject(final_included, &(&1.content == ""))

    # Build messages
    messages = Enum.map(message_pieces, &%{role: &1.role, content: &1.content})

    # Extract tool definitions from included pieces
    tools =
      final_included
      |> Enum.filter(&(&1.type == :tool_def and not is_nil(&1.metadata)))
      |> Enum.map(& &1.metadata)

    # Compute total tokens
    total_tokens = sum_tokens(final_included)

    cache_breakpoint = compute_cache_breakpoint(message_pieces)

    %RenderResult{
      messages: messages,
      tools: tools,
      total_tokens: total_tokens,
      budget: budget,
      threshold: threshold,
      included: final_included,
      dropped: all_dropped,
      fallbacks_used: all_fallbacks,
      cache_breakpoint: cache_breakpoint,
      condition_excluded: condition_excluded
    }
  end

  # Internal function — public for testability, not part of public API.
  @doc false
  @spec find_threshold([ContentPiece.t()], non_neg_integer(), module()) :: number()
  def find_threshold(pieces, budget, tokenizer) do
    levels =
      pieces
      |> Enum.map(& &1.priority)
      |> Enum.reject(&(&1 == :infinity))
      |> Enum.uniq()
      |> Enum.sort()

    case levels do
      [] ->
        0

      _ ->
        # Sentinel above all real levels — if binary search converges
        # to it, nothing (except :infinity) fits.
        sentinel = List.last(levels) + 1
        all_levels = levels ++ [sentinel]
        levels_tuple = List.to_tuple(all_levels)

        # Precompute min costs once (avoids recomputing fallback token
        # counts on every binary search probe).
        costed = Enum.map(pieces, &{&1, min_token_cost(&1, tokenizer)})

        binary_search(levels_tuple, -1, tuple_size(levels_tuple) - 1, budget, costed)
    end
  end

  # Binary search: find lowest index in levels where tokens at that threshold fit.
  # lower is exclusive, upper is inclusive.
  defp binary_search(levels, lower, upper, _budget, _costed)
       when lower >= upper - 1 do
    elem(levels, upper)
  end

  defp binary_search(levels, lower, upper, budget, costed) do
    mid = div(lower + upper, 2)
    threshold = elem(levels, mid)
    tokens = count_at_threshold(costed, threshold)

    if tokens <= budget do
      binary_search(levels, lower, mid, budget, costed)
    else
      binary_search(levels, mid, upper, budget, costed)
    end
  end

  # Sum precomputed min costs for pieces at or above threshold.
  defp count_at_threshold(costed, threshold) do
    Enum.reduce(costed, 0, fn {piece, cost}, acc ->
      if priority_gte?(piece.priority, threshold), do: acc + cost, else: acc
    end)
  end

  defp min_token_cost(piece, tokenizer) do
    # Truncatable pieces can fit in any remaining space (down to just overhead)
    case piece.overflow do
      overflow when overflow in [:truncate_end, :truncate_middle] ->
        min(piece.token_count, tokenizer.message_overhead())

      :error ->
        min_token_cost_with_fallbacks(piece, tokenizer)
    end
  end

  defp min_token_cost_with_fallbacks(%{fallbacks: []} = piece, _tokenizer) do
    piece.token_count
  end

  defp min_token_cost_with_fallbacks(piece, tokenizer) do
    fallback_costs =
      Enum.map(piece.fallbacks, fn fb ->
        tokenizer.count_tokens(fb) + tokenizer.message_overhead()
      end)

    Enum.min([piece.token_count | fallback_costs])
  end

  defp split_at_threshold(pieces, threshold) do
    Enum.split_with(pieces, &priority_gte?(&1.priority, threshold))
  end

  # Evaluate conditions: partition into kept pieces and condition-excluded pieces
  defp evaluate_conditions(pieces) do
    Enum.split_with(pieces, fn piece ->
      is_nil(piece.condition) or piece.condition.()
    end)
  end

  # Render sections independently with their own sub-budgets.
  # Returns {main_pieces, section_dropped, section_fallbacks} where main_pieces
  # contains non-sectioned pieces plus each section's surviving pieces, already
  # resolved (fallback/truncation applied). Those pieces keep their priorities
  # and compete individually in the main pass, which may drop or truncate them
  # further.
  defp render_sections(pieces, sections, _tokenizer) when map_size(sections) == 0 do
    {pieces, [], []}
  end

  defp render_sections(pieces, sections, tokenizer) do
    {section_pieces, main_pieces} = Enum.split_with(pieces, &(not is_nil(&1.section)))

    # Group section pieces by section name
    by_section = Enum.group_by(section_pieces, & &1.section)

    {resolved_pieces, all_dropped, all_fallbacks} =
      Enum.reduce(by_section, {[], [], []}, fn {name, sec_pieces}, {inc, drop, fb} ->
        case Map.get(sections, name) do
          nil ->
            # No section definition — treat as main pieces
            {sec_pieces ++ inc, drop, fb}

          section ->
            # Render this section with its own sub-budget
            {sec_included, sec_dropped, sec_fb} =
              render_section(sec_pieces, section.max_tokens, tokenizer)

            {sec_included ++ inc, sec_dropped ++ drop, sec_fb ++ fb}
        end
      end)

    {main_pieces ++ resolved_pieces, all_dropped, all_fallbacks}
  end

  # Render a single section: binary search + greedy fit within the section budget.
  # Returns included pieces with token_count set to their actual cost.
  defp render_section(pieces, max_tokens, tokenizer) do
    threshold = find_threshold(pieces, max_tokens, tokenizer)
    {above, dropped} = split_at_threshold(pieces, threshold)
    {included, extra_dropped, fallbacks} = resolve_fit(above, max_tokens, tokenizer)
    {included, dropped ++ extra_dropped, fallbacks}
  end

  # Greedy post-threshold pass: resolve fallbacks and overflow.
  #
  # Pieces are visited in priority order (highest first, ties by sequence).
  # Each piece may only consume what's left after setting aside the minimum
  # cost of every piece still pending. Since the threshold guarantees the
  # sum of minimum costs fits the budget, every piece above the threshold
  # gets at least its cheapest form, and spare budget upgrades the most
  # important pieces first (primary over fallback, longer truncation).
  #
  # Fallbacks are returned as `{original, index, resolved}` triples so the
  # caller can discard entries whose resolved piece is dropped later.
  defp resolve_fit(pieces, budget, tokenizer) do
    costed =
      pieces
      |> Enum.map(&{&1, min_token_cost(&1, tokenizer)})
      |> Enum.sort_by(fn {piece, _cost} -> fit_order_key(piece) end)

    pending = Enum.reduce(costed, 0, fn {_piece, cost}, acc -> acc + cost end)

    {included, dropped, fallbacks_used, _remaining, _pending} =
      Enum.reduce(costed, {[], [], [], budget, pending}, fn {piece, min_cost},
                                                            {inc, drop, fb, remaining, pending} ->
        pending = pending - min_cost
        available = remaining - pending

        case fit_piece(piece, available, tokenizer) do
          {:included, resolved} ->
            {[resolved | inc], drop, fb, remaining - resolved.token_count, pending}

          {:fallback, resolved, index} ->
            fb = [{piece, index, resolved} | fb]
            {[resolved | inc], drop, fb, remaining - resolved.token_count, pending}

          :dropped ->
            {inc, [piece | drop], fb, remaining, pending}
        end
      end)

    {Enum.reverse(included), Enum.reverse(dropped), Enum.reverse(fallbacks_used)}
  end

  defp fit_order_key(%{priority: :infinity, sequence: seq}), do: {0, 0, seq}
  defp fit_order_key(%{priority: priority, sequence: seq}), do: {1, -priority, seq}

  defp fit_piece(piece, available, tokenizer) do
    if piece.token_count <= available do
      {:included, piece}
    else
      try_fallbacks(piece, available, tokenizer)
    end
  end

  defp try_fallbacks(piece, available, tokenizer) do
    result =
      piece.fallbacks
      |> Enum.with_index()
      |> Enum.find_value(fn {fallback_content, index} ->
        tokens = tokenizer.count_tokens(fallback_content) + tokenizer.message_overhead()

        if tokens <= available do
          {fallback_content, tokens, index}
        end
      end)

    case result do
      # An empty fallback means "omit": report the piece as dropped.
      {"", _tokens, _index} ->
        :dropped

      {content, tokens, index} ->
        {:fallback, %{piece | content: content, token_count: tokens, fallbacks: []}, index}

      nil ->
        handle_overflow(piece, available, tokenizer)
    end
  end

  # Only reachable when :infinity pieces alone exceed the budget (the
  # threshold guarantees everything else gets at least its minimum cost).
  defp handle_overflow(%{overflow: :error} = piece, available, _tokenizer) do
    raise Winnow.OversizedContentError, piece: piece, remaining_budget: max(available, 0)
  end

  defp handle_overflow(piece, available, tokenizer) do
    if available < tokenizer.message_overhead() do
      # Can't even fit message overhead — drop the piece
      :dropped
    else
      truncate_mode = if piece.overflow == :truncate_end, do: :end, else: :middle

      case truncate_to_fit(piece, available, truncate_mode, tokenizer) do
        # No room for any content — report as dropped rather than as an
        # "included" piece that produces no message but still costs overhead.
        %{content: ""} -> :dropped
        truncated -> {:included, truncated}
      end
    end
  end

  defp truncate_to_fit(piece, remaining, mode, tokenizer) do
    overhead = tokenizer.message_overhead()
    available_tokens = remaining - overhead
    # Start with optimistic byte estimate (4 bytes/token, exact for Approximate)
    max_bytes = available_tokens * 4

    content = fit_content(piece.content, max_bytes, available_tokens, mode, tokenizer)
    token_count = tokenizer.count_tokens(content) + overhead
    %{piece | content: content, token_count: token_count}
  end

  # Truncate content to fit within available_tokens. If the initial byte
  # estimate overshoots (tokenizer has fewer bytes per token than 4),
  # iteratively shrink using the actual ratio from the tokenizer.
  defp fit_content(_original, max_bytes, _available_tokens, _mode, _tokenizer)
       when max_bytes <= 0 do
    ""
  end

  defp fit_content(original, max_bytes, available_tokens, mode, tokenizer) do
    content = truncate_content(original, max_bytes, mode)
    tokens = tokenizer.count_tokens(content)

    if tokens <= available_tokens or byte_size(content) == 0 do
      content
    else
      # Over-estimated bytes. Shrink proportionally and ensure progress.
      new_max = min(div(max_bytes * available_tokens, tokens), byte_size(content) - 1)
      fit_content(original, max(new_max, 0), available_tokens, mode, tokenizer)
    end
  end

  defp truncate_content(original, max_bytes, :end) do
    truncate_bytes(original, max_bytes)
  end

  defp truncate_content(original, max_bytes, :middle) do
    if byte_size(original) <= max_bytes do
      original
    else
      marker = " [...] "
      marker_bytes = byte_size(marker)
      usable = max(max_bytes - marker_bytes, 0)
      half = div(usable, 2)
      prefix = truncate_bytes(original, half)
      suffix = truncate_bytes_from_end(original, half)

      # A bare marker carries no content; treat it as nothing fitting.
      if prefix == "" and suffix == "", do: "", else: prefix <> marker <> suffix
    end
  end

  # Truncate string to at most max_bytes, respecting UTF-8 boundaries.
  # Tracks byte offset and uses binary_part/3 for O(n) performance.
  defp truncate_bytes(string, max_bytes) do
    used = truncate_bytes_used(string, max_bytes, 0)
    binary_part(string, 0, used)
  end

  defp truncate_bytes_used(<<>>, _remaining, used), do: used

  defp truncate_bytes_used(string, remaining, used) do
    case String.next_grapheme(string) do
      nil ->
        used

      {grapheme, rest} ->
        grapheme_bytes = byte_size(grapheme)

        if grapheme_bytes <= remaining do
          truncate_bytes_used(rest, remaining - grapheme_bytes, used + grapheme_bytes)
        else
          used
        end
    end
  end

  # Take up to max_bytes from the end of a string, at UTF-8 boundaries
  defp truncate_bytes_from_end(string, max_bytes) do
    graphemes = String.graphemes(string)

    graphemes
    |> Enum.reverse()
    |> Enum.reduce_while({<<>>, 0}, fn grapheme, {acc, used} ->
      bytes = byte_size(grapheme)

      if used + bytes <= max_bytes do
        {:cont, {grapheme <> acc, used + bytes}}
      else
        {:halt, {acc, used}}
      end
    end)
    |> elem(0)
  end

  # Empty content produces no message, so it costs nothing unless the caller
  # set token_count explicitly (as reservations do).
  defp compute_token_costs(pieces, tokenizer) do
    Enum.map(pieces, fn
      %{token_count: count} = piece when not is_nil(count) ->
        piece

      %{content: ""} = piece ->
        %{piece | token_count: 0}

      piece ->
        tokens = tokenizer.count_tokens(piece.content) + tokenizer.message_overhead()
        %{piece | token_count: tokens}
    end)
  end

  # Finds the index into messages of the last cacheable piece.
  # Expects pre-filtered message_pieces (no empty-content reservations).
  defp compute_cache_breakpoint(message_pieces) do
    result =
      message_pieces
      |> Enum.with_index()
      |> Enum.filter(fn {piece, _idx} -> piece.cacheable end)
      |> List.last()

    case result do
      nil -> nil
      {_piece, idx} -> idx
    end
  end

  defp sum_tokens(pieces) do
    Enum.reduce(pieces, 0, fn piece, acc -> acc + piece.token_count end)
  end

  # :infinity is always >= any threshold
  defp priority_gte?(:infinity, _threshold), do: true
  defp priority_gte?(priority, threshold), do: priority >= threshold
end
