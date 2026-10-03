defmodule Winnow.Renderer do
  @moduledoc """
  Renders a Winnow prompt into a `RenderResult`.

  Implements the priority-based binary search threshold algorithm
  inspired by Priompt/Cursor. The pipeline:

  1. Evaluate conditions
  2. Compute token counts for all pieces
  3. Resolve sections within their own sub-budgets
  4. Binary search for the lowest threshold where the pieces at or above it
     fit the budget in their cheapest form (smallest fallback, an empty
     "omit" fallback, or the smallest non-empty truncation)
  5. Greedy pass in priority order: each piece takes its primary, a
     fallback, or a truncation — whatever fits after setting aside the
     minimum cost of every lower-priority piece still pending
  6. Sort by sequence, build messages, populate RenderResult

  Because of step 5's reservation, every piece above the threshold is
  included with real content, except one whose cheapest option is an empty
  (`""`, "omit") fallback, which is reported as dropped. A truncatable
  piece's cheapest form is its smallest non-empty truncation.
  `Winnow.OversizedContentError` can only occur when `:infinity`-priority
  pieces alone exceed the budget.
  """

  alias Winnow.ContentPiece
  alias Winnow.RenderResult

  @truncation_marker " [...] "

  @doc """
  Renders the accumulated prompt pieces within the token budget.
  """
  @spec render(Winnow.t()) :: RenderResult.t()
  def render(%Winnow{} = winnow) do
    tokenizer = winnow.tokenizer
    budget = winnow.budget

    # Step 1: Evaluate conditions — exclude pieces where condition is falsy
    {pieces, condition_excluded} = evaluate_conditions(winnow.pieces)

    # Step 2: Compute token costs. Each piece then travels as an entry
    # {original, current, fallback_index} so results can report the original
    # of anything dropped, and which fallback a kept piece ended up using,
    # without comparing structs.
    entries =
      pieces
      |> compute_token_costs(tokenizer)
      |> Enum.map(&{&1, &1, nil})

    # Step 3: Render sections independently within their sub-budgets
    {main_entries, section_dropped} = render_sections(entries, winnow.sections, tokenizer)

    # Steps 4-5: Threshold over cheapest forms, then greedy fit
    {threshold, included_entries, main_dropped} =
      fit_entries(main_entries, budget, tokenizer, nil)

    all_dropped = Enum.map(main_dropped ++ section_dropped, &original/1)

    all_fallbacks =
      for {original, _current, index} <- included_entries, index != nil, do: {original, index}

    final_included = Enum.map(included_entries, &current/1)

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

  # Cheapest form a piece can take: its primary, any fallback, or (if
  # truncatable) the smallest truncation that still carries content.
  defp min_token_cost(piece, tokenizer) do
    fallback_costs = Enum.map(piece.fallbacks, &fallback_cost(&1, tokenizer))

    truncation_costs =
      case piece.overflow do
        :error -> []
        mode -> [min_truncation_cost(piece.content, truncate_mode(mode), tokenizer)]
      end

    Enum.min([piece.token_count | fallback_costs ++ truncation_costs])
  end

  # An empty fallback means "omit", which costs nothing.
  defp fallback_cost("", _tokenizer), do: 0

  defp fallback_cost(fallback, tokenizer),
    do: tokenizer.count_tokens(fallback) + tokenizer.message_overhead()

  defp min_truncation_cost(content, mode, tokenizer) do
    case minimal_truncation(content, mode) do
      "" -> 0
      minimal -> tokenizer.count_tokens(minimal) + tokenizer.message_overhead()
    end
  end

  defp truncate_mode(:truncate_end), do: :end
  defp truncate_mode(:truncate_middle), do: :middle

  # Evaluate conditions: partition into kept pieces and condition-excluded pieces
  defp evaluate_conditions(pieces) do
    Enum.split_with(pieces, fn piece ->
      is_nil(piece.condition) or piece.condition.()
    end)
  end

  defp original({original, _current, _index}), do: original
  defp current({_original, current, _index}), do: current

  # Render sections independently with their own sub-budgets. Returns
  # {main_entries, section_dropped}: main_entries holds unsectioned entries
  # plus each section's survivors, already resolved (fallback/truncation
  # applied). Survivors keep their priorities and compete individually in
  # the main pass, which may drop or truncate them further. Pieces naming
  # an undefined section are treated as unsectioned.
  defp render_sections(entries, sections, tokenizer) do
    {sectioned, unsectioned} =
      Enum.split_with(entries, &Map.has_key?(sections, current(&1).section))

    results =
      sectioned
      |> Enum.group_by(&current(&1).section)
      |> Enum.map(fn {name, section_entries} ->
        section = Map.fetch!(sections, name)

        {_threshold, kept, dropped} =
          fit_entries(section_entries, section.max_tokens, tokenizer, name)

        {kept, dropped}
      end)

    {unsectioned ++ Enum.flat_map(results, &elem(&1, 0)), Enum.flat_map(results, &elem(&1, 1))}
  end

  # Binary-search the threshold over the entries' cheapest forms, drop those
  # below it, and greedily fit the rest. `scope` is the section name (nil for
  # the main pass), used for error context.
  defp fit_entries(entries, budget, tokenizer, scope) do
    threshold = entries |> Enum.map(&current/1) |> find_threshold(budget, tokenizer)

    {above, below} = Enum.split_with(entries, &priority_gte?(current(&1).priority, threshold))
    {included, dropped} = resolve_fit(above, budget, tokenizer, scope)
    {threshold, included, below ++ dropped}
  end

  # Greedy post-threshold pass: resolve fallbacks and overflow.
  #
  # Entries are visited in priority order (highest first, ties by sequence).
  # Each may only consume what's left after setting aside the minimum cost
  # of every entry still pending. Since the threshold guarantees the sum of
  # minimum costs fits the budget, every entry above the threshold gets at
  # least its cheapest form, and spare budget upgrades the most important
  # pieces first (primary over fallback, longer truncation).
  defp resolve_fit(entries, budget, tokenizer, scope) do
    costed =
      entries
      |> Enum.map(&{&1, min_token_cost(current(&1), tokenizer)})
      |> Enum.sort_by(fn {entry, _cost} -> fit_order_key(current(entry)) end)

    pending = Enum.reduce(costed, 0, fn {_entry, cost}, acc -> acc + cost end)

    {included, dropped, _remaining, _pending} =
      Enum.reduce(costed, {[], [], budget, pending}, fn {{original, piece, fb_index} = entry,
                                                         min_cost},
                                                        {inc, drop, remaining, pending} ->
        pending = pending - min_cost
        available = remaining - pending

        case fit_piece(piece, available, tokenizer, scope) do
          {:included, resolved} ->
            {[{original, resolved, fb_index} | inc], drop, remaining - resolved.token_count,
             pending}

          {:fallback, resolved, index} ->
            {[{original, resolved, index} | inc], drop, remaining - resolved.token_count, pending}

          :dropped ->
            {inc, [entry | drop], remaining, pending}
        end
      end)

    {Enum.reverse(included), Enum.reverse(dropped)}
  end

  defp fit_order_key(%{priority: :infinity, sequence: seq}), do: {0, 0, seq}
  defp fit_order_key(%{priority: priority, sequence: seq}), do: {1, -priority, seq}

  defp fit_piece(piece, available, tokenizer, scope) do
    if piece.token_count <= available do
      {:included, piece}
    else
      try_fallbacks(piece, available, tokenizer, scope)
    end
  end

  defp try_fallbacks(piece, available, tokenizer, scope) do
    result =
      piece.fallbacks
      |> Enum.with_index()
      |> Enum.find_value(fn {fallback_content, index} ->
        tokens = fallback_cost(fallback_content, tokenizer)

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
        handle_overflow(piece, available, tokenizer, scope)
    end
  end

  # Only reachable when :infinity pieces alone exceed the budget, or their
  # section's max_tokens (the threshold guarantees everything else gets at
  # least its minimum cost).
  defp handle_overflow(%{overflow: :error} = piece, available, _tokenizer, scope) do
    raise Winnow.OversizedContentError,
      piece: piece,
      remaining_budget: max(available, 0),
      section: scope
  end

  defp handle_overflow(piece, available, tokenizer, _scope) do
    if available < tokenizer.message_overhead() do
      # Can't even fit message overhead — drop the piece
      :dropped
    else
      case truncate_to_fit(piece, available, truncate_mode(piece.overflow), tokenizer) do
        # No room for any content — report as dropped rather than as an
        # "included" piece that produces no message but still costs overhead.
        %{content: ""} ->
          :dropped

        # Nothing was cut, yet the piece didn't fit: its explicit token_count
        # disagrees with the tokenizer, so a recount can't be trusted.
        %{content: content} when content == piece.content ->
          :dropped

        truncated ->
          {:included, truncated}
      end
    end
  end

  defp truncate_to_fit(piece, remaining, mode, tokenizer) do
    overhead = tokenizer.message_overhead()
    content = fit_content(piece.content, remaining - overhead, mode, tokenizer)
    %{piece | content: content, token_count: tokenizer.count_tokens(content) + overhead}
  end

  # Largest truncation whose token count fits in available_tokens. Gallops
  # out from a ~4 bytes/token guess, then binary searches the byte budget,
  # so it holds for any tokenizer's ratio (the guess only affects speed).
  # If the search finds nothing (a non-monotonic tokenizer), use the minimal
  # truncation when it fits — min_token_cost reserved exactly that much.
  defp fit_content(original, available_tokens, mode, tokenizer) do
    fits? = &(tokenizer.count_tokens(&1) <= available_tokens)
    size = byte_size(original)
    guess = (available_tokens * 4) |> max(1) |> min(size)
    {lo, hi} = bracket(original, mode, fits?, 0, guess, size)

    case search_bytes(original, lo, hi, mode, fits?) do
      "" ->
        minimal = minimal_truncation(original, mode)
        if fits?.(minimal), do: minimal, else: ""

      content ->
        content
    end
  end

  # Doubles `probe` until it stops fitting (or reaches the full size).
  # Returns {lo, hi} where truncating to `lo` bytes fits.
  defp bracket(original, mode, fits?, lo, probe, size) do
    cond do
      not fits?.(truncate_content(original, probe, mode)) -> {lo, probe - 1}
      probe >= size -> {probe, probe}
      true -> bracket(original, mode, fits?, probe, min(probe * 2, size), size)
    end
  end

  # Invariant: truncating to `lo` bytes fits ("" always does).
  defp search_bytes(original, lo, hi, mode, _fits?) when lo >= hi do
    truncate_content(original, lo, mode)
  end

  defp search_bytes(original, lo, hi, mode, fits?) do
    mid = div(lo + hi + 1, 2)

    if fits?.(truncate_content(original, mid, mode)) do
      search_bytes(original, mid, hi, mode, fits?)
    else
      search_bytes(original, lo, mid - 1, mode, fits?)
    end
  end

  # Smallest truncation that still carries content.
  defp minimal_truncation(original, :end) do
    case String.next_grapheme(original) do
      {first, _rest} -> first
      nil -> ""
    end
  end

  defp minimal_truncation(original, :middle) do
    case String.next_grapheme(original) do
      {first, rest} when rest != "" -> first <> @truncation_marker <> last_grapheme(original)
      _ -> original
    end
  end

  defp truncate_content(original, max_bytes, :end) do
    truncate_bytes(original, max_bytes)
  end

  defp truncate_content(original, max_bytes, :middle) do
    if byte_size(original) <= max_bytes do
      original
    else
      usable = max(max_bytes - byte_size(@truncation_marker), 0)
      half = div(usable, 2)
      prefix = truncate_bytes(original, half)
      suffix = truncate_bytes_from_end(original, half)

      # A bare marker carries no content; treat it as nothing fitting.
      if prefix == "" and suffix == "",
        do: "",
        else: prefix <> @truncation_marker <> suffix
    end
  end

  # First max_bytes of a string, cut at a grapheme boundary.
  defp truncate_bytes(string, max_bytes) do
    binary_part(string, 0, boundary_at_or_before(string, max_bytes))
  end

  # Last max_bytes of a string, cut at a grapheme boundary.
  defp truncate_bytes_from_end(string, max_bytes) do
    size = byte_size(string)
    start = boundary_at_or_after(string, max(size - max_bytes, 0))
    binary_part(string, start, size - start)
  end

  defp last_grapheme(string) do
    size = byte_size(string)
    start = boundary_at_or_before(string, size - 1)
    binary_part(string, start, size - start)
  end

  # Grapheme boundaries are found by segmenting only a window around the
  # offset, so a cut doesn't re-segment the whole string — the truncation
  # search makes many cuts into potentially large content. The window starts
  # at a provably real boundary (see safe_boundary_at_or_before/2), which
  # makes every grapheme start inside it exact.
  @grapheme_context_bytes 64

  defp boundary_at_or_before(string, offset) when offset >= byte_size(string),
    do: byte_size(string)

  defp boundary_at_or_before(_string, offset) when offset <= 0, do: 0

  defp boundary_at_or_before(string, offset) do
    string
    |> grapheme_starts(offset, @grapheme_context_bytes)
    |> Enum.filter(&(&1 <= offset))
    |> Enum.max()
  end

  defp boundary_at_or_after(string, offset, context \\ @grapheme_context_bytes)

  defp boundary_at_or_after(string, offset, _context) when offset >= byte_size(string),
    do: byte_size(string)

  defp boundary_at_or_after(_string, offset, _context) when offset <= 0, do: 0

  defp boundary_at_or_after(string, offset, context) do
    case string |> grapheme_starts(offset, context) |> Enum.filter(&(&1 >= offset)) do
      # The cluster containing offset runs past the window; widen it. The
      # string's end always counts, so this terminates.
      [] -> boundary_at_or_after(string, offset, context * 2)
      starts -> Enum.min(starts)
    end
  end

  # Exact grapheme start offsets in a window around offset. The window's
  # start is a real boundary, so it's included; its end is cut arbitrarily,
  # so only counts when it is the string's end.
  defp grapheme_starts(string, offset, context) do
    size = byte_size(string)

    start =
      safe_boundary_at_or_before(string, codepoint_start_before(string, max(offset - context, 0)))

    stop = codepoint_start_after(string, min(offset + context, size))

    ends =
      string
      |> binary_part(start, stop - start)
      |> String.graphemes()
      |> Enum.scan(start, &(byte_size(&1) + &2))

    starts = [start | ends]
    if stop == size, do: starts, else: Enum.drop(starts, -1)
  end

  # Nearest codepoint boundary at or before p that is certainly a grapheme
  # boundary. Pairwise segmentation (x <> y splitting) can be fooled only by
  # rules that look further back: regional-indicator pairing (flags), emoji
  # ZWJ sequences, and Indic conjuncts. All of those need x to be a regional
  # indicator or to attach to what precedes it (ZWJ, combining marks), so
  # such positions are skipped.
  defp safe_boundary_at_or_before(_string, 0), do: 0

  defp safe_boundary_at_or_before(string, p) do
    prev = codepoint_start_before(string, p - 1)
    x = binary_part(string, prev, p - prev)
    y = string |> binary_part(p, min(4, byte_size(string) - p)) |> first_codepoint()

    if regional_indicator?(x) or attaches?(x) or not match?([_, _], String.graphemes(x <> y)),
      do: safe_boundary_at_or_before(string, prev),
      else: p
  end

  defp first_codepoint(binary) do
    case String.next_codepoint(binary) do
      {codepoint, _rest} -> codepoint
      nil -> ""
    end
  end

  defp regional_indicator?(<<codepoint::utf8>>), do: codepoint in 0x1F1E6..0x1F1FF
  defp regional_indicator?(_), do: false

  defp attaches?(codepoint), do: match?([_], String.graphemes("a" <> codepoint))

  defp codepoint_start_after(string, offset) do
    if offset < byte_size(string) and continuation_byte?(string, offset),
      do: codepoint_start_after(string, offset + 1),
      else: offset
  end

  defp codepoint_start_before(string, offset) do
    if offset > 0 and continuation_byte?(string, offset),
      do: codepoint_start_before(string, offset - 1),
      else: offset
  end

  defp continuation_byte?(string, offset),
    do: Bitwise.band(:binary.at(string, offset), 0b1100_0000) == 0b1000_0000

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
