defmodule Winnow.Renderer do
  @moduledoc """
  Renders a Winnow prompt into a `RenderResult`.

  Implements a priority-threshold algorithm inspired by Priompt/Cursor.
  The pipeline:

  1. Evaluate conditions
  2. Compute token counts for all pieces
  3. Resolve sections within their own sub-budgets; each survivor gets a
     cost cap (what the section allotted it), and is otherwise left as the
     original piece
  4. Admission, walking priority levels from highest to lowest with a
     running total of each piece's cheapest non-empty form (smallest
     fallback, or smallest non-empty truncation). A level is admitted if its
     pieces fit; the first level that doesn't fit, and everything below it,
     is rejected, and the threshold is the lowest admitted level. Pieces
     with a `""` ("omit") fallback are admitted only if they fit at their
     own level, and otherwise skipped without blocking lower levels.
  5. Greedy pass in priority order: each admitted piece takes its primary, a
     fallback, or a truncation — the best that fits within its section cap
     after setting aside the minimum cost of every piece still pending
  6. Sort by sequence, build messages, populate RenderResult

  Every admitted piece is included with real content. Adding budget never
  drops a piece except in favour of one at least as important.
  `Winnow.OversizedContentError` can only occur when `:infinity`-priority
  pieces alone exceed the budget (or their section's `max_tokens`).
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
    # {piece, cap}: always the caller's original piece, plus the most a
    # section allows it to cost (nil when unsectioned). Rendering always
    # starts from the original, so nothing is truncated twice and every
    # fallback stays available to the main pass.
    entries =
      pieces
      |> compute_token_costs(tokenizer)
      |> Enum.map(&{&1, nil})

    # Step 3: Render sections independently within their sub-budgets
    {main_entries, section_dropped} = render_sections(entries, winnow.sections, tokenizer)

    # Steps 4-5: Admit by priority level, then greedily fit
    {threshold, rendered, main_dropped} = fit_entries(main_entries, budget, tokenizer, nil)

    all_dropped = Enum.map(main_dropped ++ section_dropped, &entry_piece/1)

    all_fallbacks =
      for {original, _rendered, index} <- rendered, index != nil, do: {original, index}

    final_included = Enum.map(rendered, fn {_original, piece, _index} -> piece end)

    # Sort included by sequence for output ordering
    final_included = Enum.sort_by(final_included, & &1.sequence)

    # Messages exclude reservations (empty content) and tool definitions,
    # which are returned separately in `tools`
    message_pieces = Enum.reject(final_included, &(&1.content == "" or &1.type == :tool_def))

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
    {threshold, _admitted, _rejected} =
      pieces |> Enum.map(&{&1, nil}) |> admit(budget, tokenizer)

    threshold
  end

  # Decide which entries are eligible, walking priority levels from highest
  # to lowest with a running total of each entry's cheapest cost.
  #
  # - :infinity entries are always admitted (if they overflow, the greedy
  #   pass raises), except omittable ones (with a "" fallback) that don't fit.
  # - At each finite level, the non-omittable entries are admitted together
  #   if they fit; if not, this level and everything below is rejected and
  #   the threshold is the previous level.
  # - Omittable entries at an admitted level are admitted one by one (in
  #   sequence order) if their smallest non-empty form fits, and otherwise
  #   skipped without blocking lower levels. Omission is never used to make
  #   room for lower-priority pieces.
  #
  # Without omittable entries this is exactly "the lowest threshold whose
  # pieces fit in their cheapest forms". Returns {threshold, admitted, rejected}.
  defp admit(entries, budget, tokenizer) do
    costed = Enum.map(entries, &{&1, min_token_cost(entry_piece(&1), tokenizer)})

    {infinite, finite} =
      Enum.split_with(costed, fn {e, _} -> entry_piece(e).priority == :infinity end)

    {mandatory_inf, optional_inf} =
      Enum.split_with(infinite, fn {e, _} -> not omittable?(entry_piece(e)) end)

    used = sum_costs(mandatory_inf)

    {used, admitted, rejected} =
      admit_optional(optional_inf, used, budget, entries_of(mandatory_inf), [])

    levels =
      finite
      |> Enum.group_by(fn {e, _} -> entry_piece(e).priority end)
      |> Enum.sort_by(fn {priority, _} -> priority end, :desc)

    admit_levels(levels, used, budget, admitted, rejected, nil)
  end

  defp admit_levels([], _used, _budget, admitted, rejected, last_level),
    do: {last_level || 0, admitted, rejected}

  defp admit_levels([{priority, level} | lower], used, budget, admitted, rejected, last_level) do
    {mandatory, optional} =
      Enum.split_with(level, fn {e, _} -> not omittable?(entry_piece(e)) end)

    level_used = used + sum_costs(mandatory)

    if level_used > budget do
      rejected_rest = entries_of(level) ++ Enum.flat_map(lower, fn {_, l} -> entries_of(l) end)
      {last_level || priority + 1, admitted, rejected ++ rejected_rest}
    else
      {used, admitted, rejected} =
        admit_optional(optional, level_used, budget, admitted ++ entries_of(mandatory), rejected)

      admit_levels(lower, used, budget, admitted, rejected, priority)
    end
  end

  defp admit_optional(costed, used, budget, admitted, rejected) do
    costed
    |> Enum.sort_by(fn {e, _} -> entry_piece(e).sequence end)
    |> Enum.reduce({used, admitted, rejected}, fn {entry, cost}, {used, admitted, rejected} ->
      if used + cost <= budget,
        do: {used + cost, admitted ++ [entry], rejected},
        else: {used, admitted, rejected ++ [entry]}
    end)
  end

  defp entries_of(costed), do: Enum.map(costed, &elem(&1, 0))
  defp sum_costs(costed), do: Enum.reduce(costed, 0, fn {_, cost}, acc -> acc + cost end)

  defp entry_piece({piece, _cap}), do: piece

  defp omittable?(piece), do: "" in piece.fallbacks

  # Cheapest non-empty form a piece can take: its primary, any non-empty
  # fallback, or (if truncatable) its smallest non-empty truncation. Omission
  # ("" fallback) isn't a form; it's handled by admit/3.
  defp min_token_cost(piece, tokenizer) do
    fallback_costs =
      for fallback <- piece.fallbacks, fallback != "", do: fallback_cost(fallback, tokenizer)

    truncation_costs =
      with true <- truncatable?(piece, tokenizer),
           minimal when minimal != "" <-
             minimal_truncation(piece.content, truncate_mode(piece.overflow)) do
        [tokenizer.count_tokens(minimal) + tokenizer.message_overhead()]
      else
        _ -> []
      end

    Enum.min([piece.token_count | fallback_costs ++ truncation_costs])
  end

  # Truncation re-counts the cut content with the tokenizer, which is only
  # meaningful if the tokenizer agrees the full content costs token_count. An
  # explicit token_count above the tokenizer's view (e.g. an image behind a
  # short placeholder) can't be shrunk by cutting text.
  defp truncatable?(%{overflow: :error}, _tokenizer), do: false

  defp truncatable?(piece, tokenizer),
    do: tokenizer.count_tokens(piece.content) + tokenizer.message_overhead() >= piece.token_count

  defp fallback_cost(fallback, tokenizer),
    do: tokenizer.count_tokens(fallback) + tokenizer.message_overhead()

  defp truncate_mode(:truncate_end), do: :end
  defp truncate_mode(:truncate_middle), do: :middle

  # Evaluate conditions: partition into kept pieces and condition-excluded pieces
  defp evaluate_conditions(pieces) do
    Enum.split_with(pieces, fn piece ->
      is_nil(piece.condition) or piece.condition.()
    end)
  end

  # Render sections independently with their own sub-budgets. Returns
  # {main_entries, section_dropped}: unsectioned entries plus each section's
  # survivors, capped at the cost the section gave them. Survivors keep their
  # priorities and compete individually in the main pass, which renders them
  # from the original again, within the cap (so it may pick a cheaper form,
  # but never a costlier one). Pieces naming an undefined section are treated
  # as unsectioned.
  defp render_sections(entries, sections, tokenizer) do
    {sectioned, unsectioned} =
      Enum.split_with(entries, &Map.has_key?(sections, entry_piece(&1).section))

    results =
      sectioned
      |> Enum.group_by(&entry_piece(&1).section)
      |> Enum.map(fn {name, section_entries} ->
        section = Map.fetch!(sections, name)

        {_threshold, rendered, dropped} =
          fit_entries(section_entries, section.max_tokens, tokenizer, name)

        survivors =
          Enum.map(rendered, fn {original, piece, _index} -> {original, piece.token_count} end)

        {survivors, dropped}
      end)

    {unsectioned ++ Enum.flat_map(results, &elem(&1, 0)), Enum.flat_map(results, &elem(&1, 1))}
  end

  # Admit entries by priority, then greedily fit the admitted ones. `scope`
  # is the section name (nil for the main pass), used for error context.
  # Returns {threshold, rendered, dropped} where rendered holds
  # {original, rendered_piece, fallback_index_or_nil}.
  defp fit_entries(entries, budget, tokenizer, scope) do
    {threshold, admitted, rejected} = admit(entries, budget, tokenizer)
    {rendered, dropped} = resolve_fit(admitted, budget, tokenizer, scope)
    {threshold, rendered, rejected ++ dropped}
  end

  # Greedy post-admission pass: choose each piece's form.
  #
  # Entries are visited in priority order (highest first, ties by sequence).
  # Each may only consume what's left after setting aside the minimum cost
  # of every entry still pending (and no more than its section cap). Since
  # admission guarantees the minimum costs fit, every admitted entry gets at
  # least its cheapest non-empty form, and spare budget upgrades the most
  # important pieces first (primary over fallback, longer truncation).
  defp resolve_fit(entries, budget, tokenizer, scope) do
    costed =
      entries
      |> Enum.map(&{&1, min_token_cost(entry_piece(&1), tokenizer)})
      |> Enum.sort_by(fn {entry, _cost} -> fit_order_key(entry_piece(entry)) end)

    pending = sum_costs(costed)

    {rendered, dropped, _remaining, _pending} =
      Enum.reduce(costed, {[], [], budget, pending}, fn {{piece, cap} = entry, min_cost},
                                                        {rendered, dropped, remaining, pending} ->
        pending = pending - min_cost
        available = min(remaining - pending, cap || remaining - pending)

        case fit_piece(piece, available, tokenizer, scope) do
          {:included, resolved} ->
            {[{piece, resolved, nil} | rendered], dropped, remaining - resolved.token_count,
             pending}

          {:fallback, resolved, index} ->
            {[{piece, resolved, index} | rendered], dropped, remaining - resolved.token_count,
             pending}

          :dropped ->
            {rendered, [entry | dropped], remaining, pending}
        end
      end)

    {Enum.reverse(rendered), Enum.reverse(dropped)}
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

  # First non-empty fallback that fits ("" is omission, handled by admit/3
  # and handle_overflow/4).
  defp try_fallbacks(piece, available, tokenizer, scope) do
    result =
      piece.fallbacks
      |> Enum.with_index()
      |> Enum.find_value(fn {fallback, index} ->
        tokens = fallback != "" && fallback_cost(fallback, tokenizer)
        if tokens && tokens <= available, do: {fallback, tokens, index}
      end)

    case result do
      {content, tokens, index} ->
        {:fallback, %{piece | content: content, token_count: tokens, fallbacks: []}, index}

      nil ->
        handle_overflow(piece, available, tokenizer, scope)
    end
  end

  # Reached only when no form fits — which admission rules out except when
  # :infinity pieces alone exceed the budget (or their section's max_tokens).
  # Then: truncate if possible; otherwise omit if the piece allows it; and
  # an :infinity piece that would vanish raises instead.
  defp handle_overflow(piece, available, tokenizer, scope) do
    result =
      if truncatable?(piece, tokenizer),
        do: truncate_or_drop(piece, available, tokenizer),
        else: :dropped

    if result == :dropped and not omittable?(piece) and
         (piece.priority == :infinity or piece.overflow == :error) do
      raise Winnow.OversizedContentError,
        piece: piece,
        remaining_budget: max(available, 0),
        section: scope
    end

    result
  end

  defp truncate_or_drop(piece, available, tokenizer) do
    if available < tokenizer.message_overhead() do
      :dropped
    else
      case truncate_to_fit(piece, available, truncate_mode(piece.overflow), tokenizer) do
        # No room for any content — report as dropped rather than as an
        # "included" piece that produces no message but still costs overhead.
        %{content: ""} -> :dropped
        truncated -> {:included, truncated}
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
      prefix = middle_prefix(original, usable)
      suffix = truncate_bytes_from_end(original, usable - byte_size(prefix))

      # Both sides must carry content; a one-sided cut isn't a middle
      # truncation (and a bare marker carries nothing).
      if prefix == "" or suffix == "",
        do: "",
        else: prefix <> @truncation_marker <> suffix
    end
  end

  # Prefix gets half the room — or, if its first grapheme is bigger than
  # that, just the first grapheme, leaving the rest to the suffix.
  defp middle_prefix(original, usable) do
    case truncate_bytes(original, div(usable, 2)) do
      "" ->
        first = minimal_truncation(original, :end)
        if byte_size(first) < usable, do: first, else: ""

      prefix ->
        prefix
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
  # rules that look further back: regional-indicator pairing (flags, GB12/13),
  # emoji ZWJ sequences (GB11: x is ZWJ), and Indic conjuncts (GB9c: x is a
  # linker/extend mark and y an Indic consonant). Positions matching those
  # are skipped; anything else that splits pairwise is a real boundary.
  defp safe_boundary_at_or_before(_string, 0), do: 0

  defp safe_boundary_at_or_before(string, p) do
    prev = codepoint_start_before(string, p - 1)
    x = binary_part(string, prev, p - prev)
    y = string |> binary_part(p, min(4, byte_size(string) - p)) |> first_codepoint()

    lookbehind_risk? =
      regional_indicator?(x) or x == "\u200D" or (attaches?(x) and indic_consonant?(y))

    if lookbehind_risk? or not match?([_, _], String.graphemes(x <> y)),
      do: safe_boundary_at_or_before(string, prev),
      else: p
  end

  # Scripts with InCB=Consonant (GB9c): Devanagari through Malayalam.
  defp indic_consonant?(<<codepoint::utf8>>), do: codepoint in 0x0900..0x0D7F
  defp indic_consonant?(_), do: false

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
end
