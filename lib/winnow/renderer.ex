defmodule Winnow.Renderer do
  @moduledoc """
  Renders a Winnow prompt into a `RenderResult`.

  Implements the priority-based binary search threshold algorithm
  inspired by Priompt/Cursor. The pipeline:

  1. Compute token counts for all pieces
  2. Gather unique priority levels, sort ascending
  3. Binary search for the highest threshold where included tokens <= budget
  4. Resolve fallbacks for included pieces that don't fit
  5. Handle oversized content (error/truncate)
  6. Sort by sequence, build messages, populate RenderResult
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

    # Step 3: Render sections independently, replace with fixed-cost blocks
    {main_pieces, section_dropped, section_fallbacks} =
      render_sections(costed_pieces, winnow.sections, tokenizer)

    # Step 4: Find the threshold using minimum possible cost
    threshold = find_threshold(main_pieces, budget, tokenizer)

    # Split into included/dropped by threshold
    {above_threshold, dropped} = split_at_threshold(main_pieces, threshold)

    # Step 5: Resolve fallbacks and overflow for pieces above threshold
    {final_included, extra_dropped, fallbacks_used} =
      resolve_fit(above_threshold, budget, tokenizer)

    all_dropped = dropped ++ extra_dropped ++ section_dropped
    all_fallbacks = fallbacks_used ++ section_fallbacks

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

  # Issue #11: Internal function — public for testability, not part of public API.
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
        tokenizer.message_overhead()

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
    {kept, excluded} =
      Enum.split_with(pieces, fn piece ->
        is_nil(piece.condition) or piece.condition.()
      end)

    {kept, excluded}
  end

  # Render sections independently with their own sub-budgets.
  # Returns {main_pieces, section_dropped, section_fallbacks} where main_pieces
  # contains non-sectioned pieces plus section results as fixed-cost blocks.
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
  # Pieces above the threshold are included if they fit. If a piece
  # doesn't fit, try its fallbacks in order. If nothing fits, handle overflow.
  defp resolve_fit(pieces, budget, tokenizer) do
    # Sort by sequence for deterministic greedy pass
    sorted = Enum.sort_by(pieces, & &1.sequence)

    {included, dropped, fallbacks_used, _remaining} =
      Enum.reduce(sorted, {[], [], [], budget}, fn piece, {inc, drop, fb, remaining} ->
        if piece.token_count <= remaining do
          # Primary fits
          {[piece | inc], drop, fb, remaining - piece.token_count}
        else
          # Primary doesn't fit — try fallbacks
          try_fallbacks(piece, remaining, tokenizer, inc, drop, fb)
        end
      end)

    {Enum.reverse(included), Enum.reverse(dropped), Enum.reverse(fallbacks_used)}
  end

  defp try_fallbacks(piece, remaining, tokenizer, inc, drop, fb) do
    result =
      piece.fallbacks
      |> Enum.with_index()
      |> Enum.find_value(fn {fallback_content, index} ->
        tokens = tokenizer.count_tokens(fallback_content) + tokenizer.message_overhead()

        if tokens <= remaining do
          {:ok, fallback_content, tokens, index}
        end
      end)

    case result do
      {:ok, content, tokens, index} ->
        fallback_piece = %{piece | content: content, token_count: tokens, fallbacks: []}
        {[fallback_piece | inc], drop, [{piece, index} | fb], remaining - tokens}

      nil ->
        handle_overflow(piece, remaining, tokenizer, inc, drop, fb)
    end
  end

  defp handle_overflow(piece, remaining, tokenizer, inc, drop, fb) do
    case piece.overflow do
      :error ->
        # Empty-content pieces (e.g. reservations that slipped through) are
        # silently dropped rather than raising.
        if piece.content != "" do
          raise Winnow.OversizedContentError, piece: piece, remaining_budget: remaining
        else
          {inc, [piece | drop], fb, remaining}
        end

      mode when mode in [:truncate_end, :truncate_middle] ->
        handle_truncation(piece, remaining, mode, tokenizer, inc, drop, fb)
    end
  end

  defp handle_truncation(piece, remaining, mode, tokenizer, inc, drop, fb) do
    overhead = tokenizer.message_overhead()

    if remaining < overhead do
      # Can't even fit message overhead — drop the piece
      {inc, [piece | drop], fb, remaining}
    else
      truncate_mode = if mode == :truncate_end, do: :end, else: :middle
      truncated = truncate_to_fit(piece, remaining, truncate_mode, tokenizer)
      {[truncated | inc], drop, fb, remaining - truncated.token_count}
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
      prefix <> marker <> suffix
    end
  end

  # Truncate string to at most max_bytes, respecting UTF-8 boundaries
  defp truncate_bytes(string, max_bytes) do
    truncate_bytes_acc(string, max_bytes, <<>>)
  end

  defp truncate_bytes_acc(<<>>, _remaining, acc), do: acc

  defp truncate_bytes_acc(string, remaining, acc) do
    case String.next_grapheme(string) do
      nil ->
        acc

      {grapheme, rest} ->
        grapheme_bytes = byte_size(grapheme)

        if grapheme_bytes <= remaining do
          truncate_bytes_acc(rest, remaining - grapheme_bytes, acc <> grapheme)
        else
          acc
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

  defp compute_token_costs(pieces, tokenizer) do
    Enum.map(pieces, fn piece ->
      if piece.token_count do
        piece
      else
        tokens = tokenizer.count_tokens(piece.content) + tokenizer.message_overhead()
        %{piece | token_count: tokens}
      end
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
