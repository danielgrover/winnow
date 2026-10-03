defmodule Winnow.Renderer do
  @moduledoc """
  Renders a Winnow prompt into a `RenderResult`.

  Implements a priority-threshold algorithm inspired by Priompt/Cursor.
  The pipeline:

  1. Evaluate conditions
  2. Compute token counts and each piece's cheapest non-empty form
     (smallest fallback, or smallest non-empty truncation)
  3. Admission, walking priority levels from highest to lowest with running
     totals against the budget and each section's `max_tokens`. A level's
     unsectioned pieces are admitted if they fit; the first level where
     they don't, and everything below it, is rejected, and the threshold is
     the lowest admitted level. Each section's pieces at an admitted level
     go in as a group if they fit both limits, or else the section closes.
     Pieces with a `""` ("omit") fallback are admitted individually if they
     fit, and otherwise skipped without blocking anything.
  4. Greedy pass in priority order: each admitted piece takes its primary, a
     fallback, or a truncation — the best that fits in the budget and its
     section after setting aside the minimum cost of every piece still
     pending
  5. Sort by sequence, build messages, populate RenderResult

  Every admitted piece is included with real content. Adding budget, or
  raising a section's `max_tokens`, never drops a piece except in favour of
  one at least as important. `Winnow.OversizedContentError` can only occur
  when `:infinity`-priority pieces alone exceed the budget (or their
  section's `max_tokens`).
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
    limits = Map.new(winnow.sections, fn {name, section} -> {name, section.max_tokens} end)

    # Step 1: Evaluate conditions — exclude pieces where condition is falsy
    {pieces, condition_excluded} = evaluate_conditions(winnow.pieces)

    # Step 2: Compute token costs. Each piece then travels as an entry
    # {piece, section, min_cost}: the caller's original piece, the defined
    # section it counts against (nil if none), and its cheapest non-empty
    # form (computed once, since it may re-count large content).
    entries =
      pieces
      |> compute_token_costs(tokenizer)
      |> Enum.map(&{&1, defined_section(&1, limits), min_token_cost(&1, tokenizer)})

    # Steps 3-4: Admit by priority level against the budget and section
    # limits together, then greedily choose each admitted piece's form
    {threshold, admitted, rejected} = admit(entries, budget, limits)
    {rendered, dropped} = resolve_fit(admitted, budget, limits, tokenizer)

    all_dropped = Enum.map(rejected ++ dropped, &entry_piece/1)

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
      pieces
      |> Enum.map(&{&1, nil, min_token_cost(&1, tokenizer)})
      |> admit(budget, %{})

    threshold
  end

  # Pieces naming an undefined section are treated as unsectioned.
  defp defined_section(%{section: section}, limits) do
    if Map.has_key?(limits, section), do: section, else: nil
  end

  # Decide which entries are eligible, walking priority levels from highest
  # to lowest with running totals of each entry's cheapest cost — one for
  # the budget, and one per section against its max_tokens.
  #
  # - :infinity entries are always admitted (if they overflow, the greedy
  #   pass raises), except omittable ones (with a "" fallback) that don't fit.
  # - At each finite level, the unsectioned non-omittable entries are
  #   admitted together if they fit the budget; if not, this level and
  #   everything below is rejected and the threshold is the previous level.
  #   Then each section's non-omittable entries at that level are admitted
  #   as a group if they fit both the section's max_tokens and the budget;
  #   otherwise the section closes (see admit_section_groups/4).
  # - Omittable entries at an admitted level are admitted one by one (in
  #   sequence order) if their smallest non-empty form fits the budget and
  #   their section, and otherwise skipped without blocking lower levels.
  #
  # Checking sections and the budget in one pass means a section never
  # spends its room on a piece the budget can't hold. Without sections or
  # omittable entries this is exactly "the lowest threshold whose pieces fit
  # in their cheapest forms". Returns {threshold, admitted, rejected}.
  defp admit(entries, budget, limits) do
    {infinite, finite} = Enum.split_with(entries, &(entry_piece(&1).priority == :infinity))
    {mandatory_inf, optional_inf} = Enum.split_with(infinite, &(not omittable?(entry_piece(&1))))

    state = %{used: 0, section_used: %{}, closed: MapSet.new(), admitted: [], rejected: []}
    state = Enum.reduce(mandatory_inf, state, &take(&2, &1))
    state = admit_optional(optional_inf, state, budget, limits)

    finite
    |> Enum.group_by(&entry_piece(&1).priority)
    |> Enum.sort_by(fn {priority, _} -> priority end, :desc)
    |> admit_levels(state, budget, limits, nil)
  end

  # Lists are built by prepending; their order doesn't matter (resolve_fit
  # sorts admitted entries, and rejected ones are only reported).
  defp admit_levels([], state, _budget, _limits, last_level),
    do: {last_level || 0, state.admitted, state.rejected}

  defp admit_levels([{priority, level} | lower], state, budget, limits, last_level) do
    {mandatory, optional} = Enum.split_with(level, &(not omittable?(entry_piece(&1))))
    {unsectioned, sectioned} = Enum.split_with(mandatory, &(entry_section(&1) == nil))

    if state.used + sum_costs(unsectioned) > budget do
      rejected_rest = level ++ Enum.flat_map(lower, fn {_, l} -> l end)
      {last_level || priority + 1, state.admitted, rejected_rest ++ state.rejected}
    else
      state =
        unsectioned
        |> Enum.reduce(state, &take(&2, &1))
        |> admit_section_groups(sectioned, budget, limits)
        |> then(&admit_optional(optional, &1, budget, limits))

      admit_levels(lower, state, budget, limits, priority)
    end
  end

  # Each section's pieces at a level go in all-or-nothing, groups in order of
  # their earliest sequence, if they fit both the section and the budget. A
  # group that doesn't fit closes its section (it and everything below it in
  # that section is rejected) rather than blocking the rest of the prompt —
  # so giving a section more room can never push out unrelated pieces.
  defp admit_section_groups(state, sectioned, budget, limits) do
    sectioned
    |> Enum.group_by(&entry_section/1)
    |> Enum.sort_by(fn {_section, entries} ->
      entries |> Enum.map(&entry_piece(&1).sequence) |> Enum.min()
    end)
    |> Enum.reduce(state, fn {section, entries}, state ->
      cost = sum_costs(entries)

      fits? =
        open?(state, hd(entries)) and state.used + cost <= budget and
          Map.get(state.section_used, section, 0) + cost <= Map.fetch!(limits, section)

      if fits?,
        do: Enum.reduce(entries, state, &take(&2, &1)),
        else: %{
          state
          | closed: MapSet.put(state.closed, section),
            rejected: entries ++ state.rejected
        }
    end)
  end

  defp admit_optional(entries, state, budget, limits) do
    entries
    |> Enum.sort_by(&entry_piece(&1).sequence)
    |> Enum.reduce(state, fn entry, state ->
      if open?(state, entry) and fits?(state, entry, budget, limits),
        do: take(state, entry),
        else: %{state | rejected: [entry | state.rejected]}
    end)
  end

  defp fits?(state, {_piece, section, cost}, budget, limits) do
    state.used + cost <= budget and
      (section == nil or Map.get(state.section_used, section, 0) + cost <= limits[section])
  end

  defp take(state, {_piece, section, cost} = entry) do
    section_used =
      if section,
        do: Map.update(state.section_used, section, cost, &(&1 + cost)),
        else: state.section_used

    %{
      state
      | used: state.used + cost,
        section_used: section_used,
        admitted: [entry | state.admitted]
    }
  end

  defp open?(state, entry), do: not MapSet.member?(state.closed, entry_section(entry))

  defp sum_costs(entries), do: Enum.reduce(entries, 0, fn {_, _, cost}, acc -> acc + cost end)

  defp entry_piece({piece, _section, _min_cost}), do: piece
  defp entry_section({_piece, section, _min_cost}), do: section

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

  # Greedy post-admission pass: choose each piece's form.
  #
  # Entries are visited in priority order (highest first, ties by sequence).
  # Each may only consume what's left — in the budget and in its section —
  # after setting aside the minimum cost of every entry still pending there.
  # Since admission guarantees those minimums fit, every admitted entry gets
  # at least its cheapest non-empty form, and spare room upgrades the most
  # important pieces first (primary over fallback, longer truncation).
  # Returns {rendered, dropped} with rendered as
  # {original, rendered_piece, fallback_index_or_nil}.
  defp resolve_fit(entries, budget, limits, tokenizer) do
    sorted = Enum.sort_by(entries, &fit_order_key(entry_piece(&1)))

    pending =
      Enum.reduce(sorted, %{nil => 0}, fn {_, section, cost}, acc ->
        charge(acc, section, cost)
      end)

    remaining = Map.put(limits, nil, budget)

    {rendered, dropped, _remaining, _pending} =
      Enum.reduce(sorted, {[], [], remaining, pending}, fn {piece, section, min_cost} = entry,
                                                           {rendered, dropped, remaining, pending} ->
        pending = charge(pending, section, -min_cost)
        {available, scope} = available(remaining, pending, section)

        case fit_piece(piece, available, tokenizer, scope) do
          :dropped ->
            {rendered, [entry | dropped], remaining, pending}

          {_form, resolved, index} ->
            remaining = charge(remaining, section, -resolved.token_count)
            {[{piece, resolved, index} | rendered], dropped, remaining, pending}
        end
      end)

    {Enum.reverse(rendered), Enum.reverse(dropped)}
  end

  # Apply `amount` to the budget (key nil) and, if any, the piece's section.
  defp charge(totals, section, amount) do
    totals = Map.update(totals, nil, amount, &(&1 + amount))
    if section, do: Map.update(totals, section, amount, &(&1 + amount)), else: totals
  end

  # Room left for a piece: the tighter of the budget and its section, each
  # net of pending minimums. `scope` names the section when it's the binding
  # constraint (for error messages).
  defp available(remaining, pending, section) do
    main = remaining[nil] - pending[nil]

    with section when section != nil <- section,
         in_section = remaining[section] - pending[section],
         true <- in_section < main do
      {in_section, section}
    else
      _ -> {main, nil}
    end
  end

  defp fit_order_key(%{priority: :infinity, sequence: seq}), do: {0, 0, seq}
  defp fit_order_key(%{priority: priority, sequence: seq}), do: {1, -priority, seq}

  defp fit_piece(piece, available, tokenizer, scope) do
    if piece.token_count <= available do
      {:primary, piece, nil}
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
        truncated -> {:truncated, truncated, nil}
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

      # The prefix gets half the room, or just the first grapheme if that's
      # bigger. The suffix's room depends only on `usable` and that first
      # grapheme (not on where the prefix happened to cut), so both sides
      # only grow as max_bytes grows — fit_content's search relies on it.
      first_size = original |> minimal_truncation(:end) |> byte_size()
      prefix_room = max(div(usable, 2), first_size)
      prefix = if prefix_room < usable, do: truncate_bytes(original, prefix_room), else: ""
      suffix = truncate_bytes_from_end(original, usable - prefix_room)

      # Both sides must carry content; a one-sided cut isn't a middle
      # truncation (and a bare marker carries nothing).
      if prefix == "" or suffix == "",
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
  # rules that look further back: regional-indicator pairing (flags, GB12/13),
  # emoji ZWJ sequences (GB11: x is ZWJ and y an emoji), and conjuncts (GB9c:
  # y is an InCB consonant after marks that include a linker). Positions matching those
  # are skipped; anything else that splits pairwise is a real boundary.
  defp safe_boundary_at_or_before(_string, 0), do: 0

  defp safe_boundary_at_or_before(string, p) do
    prev = codepoint_start_before(string, p - 1)
    x = binary_part(string, prev, p - prev)
    y = string |> binary_part(p, min(4, byte_size(string) - p)) |> first_codepoint()

    lookbehind_risk? =
      regional_indicator?(x) or
        (x == "\u200D" and extended_pictographic?(y)) or
        (indic_consonant?(y) and linker_before?(string, p))

    if lookbehind_risk? or not match?([_, _], String.graphemes(x <> y)),
      do: safe_boundary_at_or_before(string, prev),
      else: p
  end

  # These classify codepoints by asking Elixir's own segmenter, so they track
  # its Unicode version (e.g. GB9c covers Devanagari, Myanmar, Sinhala,
  # Khmer, ... — whatever the tables assign).

  # InCB=Consonant: joins a preceding consonant + virama.
  defp indic_consonant?(""), do: false
  defp indic_consonant?(y), do: match?([_], String.graphemes("क्" <> y))

  # InCB=Linker (a virama): makes two consonants one cluster.
  defp linker?(codepoint), do: match?([_], String.graphemes("क" <> codepoint <> "क"))

  # Extended_Pictographic: joins after an emoji + ZWJ (GB11).
  defp extended_pictographic?(""), do: false
  defp extended_pictographic?(y), do: match?([_], String.graphemes("👨\u200D" <> y))

  # Is there a linker among the combining marks just before p? GB9c only
  # joins a consonant across such a run when it contains one; vowel signs
  # alone (e.g. "का" repeated) don't, so those positions stay safe.
  defp linker_before?(_string, p) when p <= 0, do: false

  defp linker_before?(string, p) do
    prev = codepoint_start_before(string, p - 1)
    codepoint = binary_part(string, prev, p - prev)

    cond do
      linker?(codepoint) -> true
      attaches?(codepoint) -> linker_before?(string, prev)
      true -> false
    end
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
end
