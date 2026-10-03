defmodule Winnow.RendererTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Winnow.ContentPiece
  alias Winnow.Renderer

  # Helper to build a costed piece (token_count pre-set)
  defp piece(attrs) do
    defaults = %{role: :user, content: "x", priority: 500, sequence: 0, token_count: 10}
    ContentPiece.new!(Map.merge(defaults, Map.new(attrs)))
  end

  @tokenizer Winnow.Tokenizer.Approximate

  describe "find_threshold/3" do
    test "empty pieces returns 0" do
      assert Renderer.find_threshold([], 100, @tokenizer) == 0
    end

    test "single piece that fits returns its priority" do
      pieces = [piece(priority: 500, token_count: 10)]
      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 500
    end

    test "single piece that doesn't fit — threshold above it" do
      pieces = [piece(priority: 500, token_count: 200)]
      # Nothing fits, so the threshold is one above the highest level
      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 501
    end

    test "two pieces, both fit — threshold is lowest priority" do
      pieces = [
        piece(priority: 1000, token_count: 30),
        piece(priority: 500, token_count: 30, sequence: 1)
      ]

      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 500
    end

    test "two pieces, only high-priority fits — threshold is high" do
      pieces = [
        piece(priority: 1000, token_count: 80),
        piece(priority: 500, token_count: 80, sequence: 1)
      ]

      # Both = 160, too much. Only 1000 = 80, fits.
      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 1000
    end

    test "three priority levels" do
      pieces = [
        piece(priority: 1000, token_count: 40),
        piece(priority: 500, token_count: 40, sequence: 1),
        piece(priority: 100, token_count: 40, sequence: 2)
      ]

      # All three = 120. Budget is 100.
      # 500+ = 80, fits.
      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 500
    end

    test "all same priority" do
      pieces = [
        piece(priority: 500, token_count: 30),
        piece(priority: 500, token_count: 30, sequence: 1),
        piece(priority: 500, token_count: 30, sequence: 2)
      ]

      # A level is admitted or rejected as a whole: 90 fits in 100...
      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 500
      # ...but at 80 the whole level is rejected, even though two would fit
      assert Renderer.find_threshold(pieces, 80, @tokenizer) == 501
    end

    test "exact budget fit" do
      pieces = [
        piece(priority: 1000, token_count: 50),
        piece(priority: 500, token_count: 50, sequence: 1)
      ]

      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 500
    end
  end

  describe "render/1 — threshold and inclusion" do
    test "empty prompt" do
      result = Winnow.new(budget: 100) |> Winnow.render()
      assert result.messages == []
      assert result.total_tokens == 0
      assert result.budget == 100
      assert result.included == []
      assert result.dropped == []
    end

    test "single piece that fits" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "Hello", token_count: 10)
        |> Winnow.render()

      assert [%{role: :system, content: "Hello"}] = result.messages
      assert result.total_tokens == 10
      assert [_] = result.included
      assert result.dropped == []
    end

    test "drops low-priority piece when over budget" do
      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:system, priority: 1000, content: "Important", token_count: 10)
        |> Winnow.add(:user, priority: 100, content: "Less important", token_count: 10)
        |> Winnow.render()

      assert [_] = result.messages
      assert [%{role: :system, content: "Important"}] = result.messages
      assert result.total_tokens == 10
      assert [_] = result.included
      assert [_] = result.dropped
      assert hd(result.dropped).priority == 100
    end

    test "zero budget drops everything except reservations" do
      result =
        Winnow.new(budget: 0)
        |> Winnow.reserve(:r, tokens: 0)
        |> Winnow.add(:system, priority: 1000, content: "Hello", token_count: 10)
        |> Winnow.render()

      assert [%{name: :r}] = result.included
      assert [%{content: "Hello"}] = result.dropped
      assert result.messages == []
      assert result.total_tokens == 0
      assert result.threshold == 1001
    end
  end

  describe "render/1 — ordering" do
    test "output ordered by sequence, not priority" do
      result =
        Winnow.new(budget: 1000)
        |> Winnow.add(:user, priority: 100, content: "First", token_count: 5)
        |> Winnow.add(:system, priority: 1000, content: "Second", token_count: 5)
        |> Winnow.add(:user, priority: 500, content: "Third", token_count: 5)
        |> Winnow.render()

      contents = Enum.map(result.messages, & &1.content)
      assert contents == ["First", "Second", "Third"]
    end
  end

  describe "render/1 — token counting" do
    test "empty content costs nothing without an explicit token_count" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 1, content: "")
        |> Winnow.render()

      assert result.total_tokens == 0
      assert result.messages == []
    end

    test "pre-computed token_count used when present" do
      result =
        Winnow.new(budget: 1000)
        |> Winnow.add(:user, priority: 500, content: "short", token_count: 999)
        |> Winnow.render()

      assert result.total_tokens == 999
    end

    test "overhead included when token_count not pre-computed" do
      # "hello" = 5 bytes, div(5,4) = 1 token content + 4 overhead = 5 total
      result =
        Winnow.new(budget: 1000)
        |> Winnow.add(:user, priority: 500, content: "hello")
        |> Winnow.render()

      assert result.total_tokens == 5
    end
  end

  describe "render/1 — metadata" do
    test "threshold, included, dropped, budget are correct" do
      result =
        Winnow.new(budget: 20)
        |> Winnow.add(:system, priority: 1000, content: "A", token_count: 10)
        |> Winnow.add(:user, priority: 500, content: "B", token_count: 10)
        |> Winnow.add(:user, priority: 100, content: "C", token_count: 10)
        |> Winnow.render()

      assert result.budget == 20
      assert result.total_tokens == 20
      assert result.threshold == 500
      assert [_, _] = result.included
      assert [_] = result.dropped

      included_priorities = Enum.map(result.included, & &1.priority)
      assert Enum.all?(included_priorities, &(&1 >= result.threshold))

      dropped_priorities = Enum.map(result.dropped, & &1.priority)
      assert Enum.all?(dropped_priorities, &(&1 < result.threshold))
    end
  end

  describe "render/1 — reserve" do
    test "reserved tokens reduce available budget" do
      result =
        Winnow.new(budget: 20)
        |> Winnow.reserve(:response, tokens: 10)
        |> Winnow.add(:system, priority: 1000, content: "A", token_count: 10)
        |> Winnow.add(:user, priority: 100, content: "B", token_count: 10)
        |> Winnow.render()

      # Budget 20, reserve 10, only room for A (10). B is dropped.
      assert result.total_tokens == 20
      assert [_] = result.messages
      assert hd(result.messages).content == "A"
    end
  end

  describe "property-based" do
    property "total_tokens never exceeds budget" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 0, max_length: 20)
            ) do
        result = build_winnow(budget, pieces) |> Winnow.render()
        assert result.total_tokens <= result.budget
      end
    end

    property "all included pieces have priority >= threshold" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 1, max_length: 20)
            ) do
        result = build_winnow(budget, pieces) |> Winnow.render()

        for piece <- result.included do
          assert piece.priority == :infinity or piece.priority >= result.threshold
        end
      end
    end

    property "no piece in both included and dropped" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 1, max_length: 20)
            ) do
        result = build_winnow(budget, pieces) |> Winnow.render()
        included_seqs = MapSet.new(result.included, & &1.sequence)
        dropped_seqs = MapSet.new(result.dropped, & &1.sequence)
        assert MapSet.disjoint?(included_seqs, dropped_seqs)
      end
    end

    property "included + dropped == all input pieces" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 0, max_length: 20)
            ) do
        w = build_winnow(budget, pieces)
        result = Winnow.render(w)
        assert length(result.included) + length(result.dropped) == length(w.pieces)
      end
    end

    property "messages are ordered by sequence" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 0, max_length: 20)
            ) do
        result = build_winnow(budget, pieces) |> Winnow.render()
        sequences = Enum.map(result.included, & &1.sequence)
        assert sequences == Enum.sort(sequences)
      end
    end

    property "cache_breakpoint is nil or valid message index" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 0, max_length: 20)
            ) do
        result = build_winnow(budget, pieces) |> Winnow.render()

        case result.cache_breakpoint do
          nil -> :ok
          idx -> assert idx >= 0 and idx < length(result.messages)
        end
      end
    end
  end

  describe "property-based — truncation respects grapheme clusters" do
    # Includes a 12-flag run: longer than the boundary search's window, so a
    # window can start mid-flag.
    @clusters [
      "a",
      "é",
      "e\u0301",
      "👋🏽",
      "👨‍👩‍👧‍👦",
      "🇯🇵",
      "中",
      " ",
      "\r\n",
      String.duplicate("🇺🇸", 12),
      String.duplicate("e\u0301\u0302", 30)
    ]

    property "truncated content is made of whole graphemes from the original" do
      check all(
              parts <- list_of(member_of(@clusters), min_length: 2, max_length: 300),
              budget <- integer(3..200),
              mode <- member_of([:truncate_end, :truncate_middle])
            ) do
        original = Enum.join(parts)
        graphemes = String.graphemes(original)

        result =
          Winnow.new(budget: budget, tokenizer: __MODULE__.ByteTokenizer)
          |> Winnow.add(:user, priority: 1, content: original, overflow: mode)
          |> Winnow.render()

        assert result.total_tokens <= budget

        for %{content: content} <- result.messages, content != original do
          case {mode, String.split(content, " [...] ", parts: 2)} do
            {:truncate_middle, [prefix, suffix]} ->
              p = String.graphemes(prefix)
              q = String.graphemes(suffix)
              assert p != [] and q != []
              assert p == Enum.take(graphemes, length(p))
              assert q == Enum.take(graphemes, -length(q))

            {:truncate_end, [prefix]} ->
              p = String.graphemes(prefix)
              assert p == Enum.take(graphemes, length(p))

            other ->
              flunk("#{mode} produced the wrong shape: #{inspect(other)}")
          end
        end
      end
    end
  end

  describe "property-based — budget monotonicity" do
    property "a bigger budget only displaces a piece in favour of one at least as important" do
      check all(
              budget <- integer(0..600),
              extra <- integer(1..300),
              tokenizer <-
                member_of([
                  Winnow.Tokenizer.Approximate,
                  __MODULE__.ByteTokenizer,
                  __MODULE__.LowOverheadTokenizer,
                  __MODULE__.ZeroOverheadByteTokenizer
                ]),
              pieces <- list_of(mixed_piece_generator(), min_length: 1, max_length: 12),
              max_runs: 1_000
            ) do
        build = fn b ->
          Enum.reduce(pieces, Winnow.new(budget: b, tokenizer: tokenizer), fn opts, acc ->
            Winnow.add(acc, :user, opts)
          end)
        end

        small = build.(budget) |> Winnow.render()
        large = build.(budget + extra) |> Winnow.render()

        seqs = fn result -> MapSet.new(result.included, & &1.sequence) end
        lost = MapSet.difference(seqs.(small), seqs.(large))
        gained = MapSet.difference(seqs.(large), seqs.(small))
        by_seq = Map.new(build.(0).pieces, &{&1.sequence, &1})

        for l <- lost do
          assert Enum.any?(gained, &outranks?(by_seq[&1], by_seq[l])),
                 "piece #{l} (priority #{by_seq[l].priority}) lost with more budget"
        end
      end
    end
  end

  describe "property-based — section monotonicity" do
    property "raising a section's max_tokens only displaces a piece for one at least as important" do
      check all(
              budget <- integer(0..400),
              max_tokens <- integer(0..300),
              extra <- integer(1..200),
              tokenizer <-
                member_of([
                  Winnow.Tokenizer.Approximate,
                  __MODULE__.ByteTokenizer,
                  __MODULE__.ZeroOverheadByteTokenizer
                ]),
              pieces <-
                list_of(
                  tuple({mixed_piece_generator(), member_of([nil, :s, :t])}),
                  min_length: 1,
                  max_length: 12
                ),
              max_runs: 1_000
            ) do
        build = fn m ->
          Enum.reduce(
            pieces,
            Winnow.new(budget: budget, tokenizer: tokenizer)
            |> Winnow.section(:s, max_tokens: m)
            |> Winnow.section(:t, max_tokens: 50),
            fn {opts, section}, acc ->
              opts = if section, do: Keyword.put(opts, :section, section), else: opts
              Winnow.add(acc, :user, opts)
            end
          )
        end

        small = build.(max_tokens) |> Winnow.render()
        large = build.(max_tokens + extra) |> Winnow.render()

        seqs = fn result -> MapSet.new(result.included, & &1.sequence) end
        lost = MapSet.difference(seqs.(small), seqs.(large))
        gained = MapSet.difference(seqs.(large), seqs.(small))
        by_seq = Map.new(build.(0).pieces, &{&1.sequence, &1})

        for l <- lost do
          assert Enum.any?(gained, &outranks?(by_seq[&1], by_seq[l])),
                 "piece #{l} (priority #{by_seq[l].priority}) lost when a section grew"
        end
      end
    end
  end

  describe "property-based — mixed overflow modes" do
    property "never raises and keeps every piece above threshold when reservations fit" do
      check all(
              budget <- integer(20..1000),
              reserve <- integer(0..10),
              tokenizer <-
                member_of([
                  Winnow.Tokenizer.Approximate,
                  __MODULE__.ByteTokenizer,
                  __MODULE__.LowOverheadTokenizer
                ]),
              pieces <- list_of(mixed_piece_generator(), min_length: 0, max_length: 20)
            ) do
        w =
          Enum.reduce(pieces, Winnow.new(budget: budget, tokenizer: tokenizer), fn opts, acc ->
            Winnow.add(acc, :user, opts)
          end)
          |> Winnow.reserve(:response, tokens: reserve)

        result = Winnow.render(w)

        assert result.total_tokens <= budget
        assert Enum.any?(result.included, &(&1.name == :response))

        # Only pieces below the threshold, or pieces resolved to an empty
        # ("omit") fallback, are dropped. Truncatable pieces above the
        # threshold always keep real content.
        for piece <- result.dropped do
          assert piece.priority < result.threshold or "" in piece.fallbacks
        end

        # Nothing "included" is invisible: every included piece that started
        # with content produces a message, and empty pieces cost nothing.
        originals = Map.new(w.pieces, &{&1.sequence, &1})

        for piece <- result.included, piece.name != :response do
          if originals[piece.sequence].content == "" do
            assert piece.token_count == 0
          else
            assert piece.content != ""
          end
        end

        assert length(result.included) + length(result.dropped) == length(w.pieces)
      end
    end
  end

  describe "render/1 — fallbacks" do
    test "primary fits, no fallback used" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 500,
          content: "Full version",
          token_count: 10,
          fallbacks: ["Short version"]
        )
        |> Winnow.render()

      assert [%{content: "Full version"}] = result.messages
      assert result.fallbacks_used == []
    end

    test "first fallback used when primary too large" do
      result =
        Winnow.new(budget: 20)
        |> Winnow.add(:system, priority: 1000, content: "System", token_count: 10)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Very long primary content",
          token_count: 15,
          fallbacks: ["Short"]
        )
        |> Winnow.render()

      contents = Enum.map(result.messages, & &1.content)
      assert "Short" in contents
      refute "Very long primary content" in contents
      assert [_] = result.fallbacks_used
      {_original_piece, index} = hd(result.fallbacks_used)
      assert index == 0
    end

    test "second fallback used when first also too large" do
      result =
        Winnow.new(budget: 20)
        |> Winnow.add(:system, priority: 1000, content: "System", token_count: 10)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Very long primary",
          token_count: 15,
          fallbacks: ["Medium fallback that is also too long", "OK"]
        )
        |> Winnow.render()

      contents = Enum.map(result.messages, & &1.content)
      assert "OK" in contents
      {_piece, index} = hd(result.fallbacks_used)
      assert index == 1
    end

    test "nothing fits — piece dropped when primary and all fallbacks too large" do
      # B's primary (30) and its only fallback (29) are too large for the
      # budget, so admission rejects B's level... but A shares the level.
      # Put B one level lower so A is admitted and B is rejected on its own.
      result =
        Winnow.new(budget: 25)
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("a", 80),
          token_count: 20,
          fallbacks: ["tiny"]
        )
        |> Winnow.add(:user,
          priority: 400,
          content: String.duplicate("b", 120),
          fallbacks: [String.duplicate("x", 100)]
        )
        |> Winnow.render()

      assert [%{content: content}] = result.messages
      assert content == String.duplicate("a", 80)
      assert [%{priority: 400}] = result.dropped
      assert result.threshold == 500
      assert result.total_tokens == 20
    end

    test "fallback preserves role and sequence" do
      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:system, priority: 1000, content: "Sys", token_count: 5)
        |> Winnow.add(:assistant,
          priority: 500,
          content: "Long response",
          token_count: 20,
          fallbacks: ["Short"]
        )
        |> Winnow.render()

      assert [_, %{role: :assistant, content: "Short"}] = result.messages
      assert [_, %{sequence: 1, role: :assistant}] = result.included
      assert result.total_tokens == 10
    end

    test "multiple pieces with fallbacks" do
      result =
        Winnow.new(budget: 25)
        |> Winnow.add(:system, priority: 1000, content: "S", token_count: 5)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Long A",
          token_count: 15,
          fallbacks: ["A"]
        )
        |> Winnow.add(:user,
          priority: 1000,
          content: "Long B",
          token_count: 15,
          fallbacks: ["B"]
        )
        |> Winnow.render()

      # Min costs 5 + 4 + 4 = 13 admit the level. In sequence order A gets its
      # primary (15) since B's minimum (4) is still reserved; B gets "B" (4).
      assert Enum.map(result.messages, & &1.content) == ["S", "Long A", "B"]
      assert [{%{content: "Long B"}, 0}] = result.fallbacks_used
      assert result.total_tokens == 24
    end
  end

  describe "render/1 — overflow" do
    test "piece above threshold never raises — earlier piece downgrades to fallback" do
      # Min costs: A=5 (fallback), B=12 → 17 <= 25. A must use its fallback
      # so B fits, rather than A taking its primary and B raising.
      result =
        Winnow.new(budget: 25)
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("a", 80),
          token_count: 20,
          fallbacks: ["tiny"]
        )
        |> Winnow.add(:user,
          priority: 500,
          content: "Needs more room than available",
          token_count: 12,
          overflow: :error
        )
        |> Winnow.render()

      assert result.total_tokens == 17
      assert [_, _] = result.included
      assert [{%{token_count: 20}, 0}] = result.fallbacks_used
    end

    test ":error raises when :infinity pieces alone exceed the budget" do
      assert_raise Winnow.OversizedContentError, fn ->
        Winnow.new(budget: 10)
        |> Winnow.add(:system, priority: :infinity, content: "x", token_count: 20)
        |> Winnow.render()
      end
    end

    test "reservation larger than the budget raises instead of being dropped" do
      assert_raise Winnow.OversizedContentError, ~r/:response/, fn ->
        Winnow.new(budget: 100)
        |> Winnow.reserve(:response, tokens: 500)
        |> Winnow.render()
      end
    end

    test ":truncate_end truncates and fits" do
      result =
        Winnow.new(budget: 30)
        |> Winnow.reserve(:response, tokens: 10)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("x", 200),
          token_count: 50,
          overflow: :truncate_end
        )
        |> Winnow.render()

      # 30 - 10 reserved - 4 overhead = 16 content tokens = up to 67 bytes
      assert result.total_tokens == 30
      assert [%{content: content}] = result.messages
      assert content == String.duplicate("x", 67)
    end

    test ":truncate_middle preserves start and end with marker" do
      original = String.duplicate("a", 100) <> String.duplicate("z", 100)

      result =
        Winnow.new(budget: 40)
        |> Winnow.reserve(:response, tokens: 10)
        |> Winnow.add(:user,
          priority: 1000,
          content: original,
          token_count: 50,
          overflow: :truncate_middle
        )
        |> Winnow.render()

      assert result.total_tokens == 40
      assert [%{content: content}] = result.messages
      assert content == String.duplicate("a", 50) <> " [...] " <> String.duplicate("z", 50)
    end

    test "non-oversized piece with overflow option not truncated" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Short",
          token_count: 5,
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert [%{content: "Short"}] = result.messages
    end

    test "UTF-8 boundary safety with truncation" do
      content = String.duplicate("é", 100)

      result =
        Winnow.new(budget: 30)
        |> Winnow.reserve(:response, tokens: 5)
        |> Winnow.add(:user,
          priority: 1000,
          content: content,
          token_count: 50,
          overflow: :truncate_end
        )
        |> Winnow.render()

      # 21 content tokens allow 87 bytes; the cut backs off to 86 so it
      # doesn't split a 2-byte "é"
      assert result.total_tokens == 30
      assert [%{content: content}] = result.messages
      assert content == String.duplicate("é", 43)
    end

    test "truncation with less than message overhead left raises for :infinity" do
      # Both :infinity pieces are mandatory. Visiting the truncatable one
      # first (lower sequence) leaves it 20 - 18 = 2 < overhead 4: it can't
      # carry content, and an :infinity piece must not vanish.
      assert_raise Winnow.OversizedContentError, ~r/smallest truncation/, fn ->
        Winnow.new(budget: 20)
        |> Winnow.add(:user,
          priority: :infinity,
          content: String.duplicate("x", 200),
          overflow: :truncate_end
        )
        |> Winnow.reserve(:response, tokens: 18)
        |> Winnow.render()
      end
    end
  end

  describe "render/1 — conditions" do
    test "nil-returning condition excludes the piece" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 500, content: "Hidden", condition: fn -> nil end)
        |> Winnow.render()

      assert result.messages == []
      assert [%{content: "Hidden"}] = result.condition_excluded
    end

    test "true condition included" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 500,
          content: "Included",
          token_count: 10,
          condition: fn -> true end
        )
        |> Winnow.render()

      assert [%{content: "Included"}] = result.messages
    end

    test "false condition excluded entirely" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 500,
          content: "Excluded",
          token_count: 10,
          condition: fn -> false end
        )
        |> Winnow.render()

      assert result.messages == []
      # Excluded by condition — not in included or dropped
      assert result.included == []
      assert result.dropped == []
    end

    test "condition-excluded pieces tracked in condition_excluded" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 500,
          content: "Hidden",
          token_count: 10,
          condition: fn -> false end
        )
        |> Winnow.add(:user, priority: 500, content: "Visible", token_count: 10)
        |> Winnow.render()

      assert [_] = result.condition_excluded
      assert hd(result.condition_excluded).content == "Hidden"
    end

    test "nil condition included" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 500, content: "Always", token_count: 10)
        |> Winnow.render()

      assert [%{content: "Always"}] = result.messages
    end

    test "excluded piece doesn't consume budget" do
      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:system,
          priority: 1000,
          content: "Huge but excluded",
          token_count: 100,
          condition: fn -> false end
        )
        |> Winnow.add(:user, priority: 500, content: "Fits", token_count: 10)
        |> Winnow.render()

      assert [%{content: "Fits"}] = result.messages
      assert result.total_tokens == 10
    end

    test "evaluated at render time, not add time" do
      :persistent_term.put({__MODULE__, :cond_flag}, false)

      w =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 500,
          content: "Dynamic",
          token_count: 10,
          condition: fn -> :persistent_term.get({__MODULE__, :cond_flag}) end
        )

      # First render: condition false
      result1 = Winnow.render(w)
      assert result1.messages == []

      # Change flag, second render: condition true
      :persistent_term.put({__MODULE__, :cond_flag}, true)
      result2 = Winnow.render(w)
      assert [%{content: "Dynamic"}] = result2.messages

      # Cleanup
      :persistent_term.erase({__MODULE__, :cond_flag})
    end
  end

  describe "render/1 — sections" do
    test "section caps tokens for its pieces" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.section(:memory, max_tokens: 15)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Mem1",
          token_count: 10,
          section: :memory
        )
        |> Winnow.add(:user,
          priority: 500,
          content: "Mem2",
          token_count: 10,
          section: :memory
        )
        |> Winnow.render()

      # Section budget 15: only Mem1 (10) fits. Mem2 dropped.
      assert Enum.map(result.messages, & &1.content) == ["Mem1"]
      assert [%{content: "Mem2"}] = result.dropped
      assert result.total_tokens == 10
    end

    test "non-sectioned pieces unaffected by section budget" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.section(:memory, max_tokens: 10)
        |> Winnow.add(:system, priority: 1000, content: "System", token_count: 20)
        |> Winnow.add(:user,
          priority: 500,
          content: "Mem",
          token_count: 8,
          section: :memory
        )
        |> Winnow.render()

      contents = Enum.map(result.messages, & &1.content)
      assert "System" in contents
      assert "Mem" in contents
    end

    test "pieces compete within section by priority" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.section(:context, max_tokens: 20)
        |> Winnow.add(:user,
          priority: 100,
          content: "Low",
          token_count: 10,
          section: :context
        )
        |> Winnow.add(:user,
          priority: 900,
          content: "High",
          token_count: 10,
          section: :context
        )
        |> Winnow.add(:user,
          priority: 500,
          content: "Mid",
          token_count: 10,
          section: :context
        )
        |> Winnow.render()

      # Section budget 20: High(10) + Mid(10) = 20 fits. Low dropped.
      contents = Enum.map(result.messages, & &1.content)
      assert "High" in contents
      assert "Mid" in contents
      refute "Low" in contents
    end

    test "multiple independent sections" do
      result =
        Winnow.new(budget: 200)
        |> Winnow.section(:memory, max_tokens: 15)
        |> Winnow.section(:tools, max_tokens: 15)
        |> Winnow.add(:user, priority: 1000, content: "M1", token_count: 10, section: :memory)
        |> Winnow.add(:user, priority: 500, content: "M2", token_count: 10, section: :memory)
        |> Winnow.add(:system, priority: 1000, content: "T1", token_count: 10, section: :tools)
        |> Winnow.add(:system, priority: 500, content: "T2", token_count: 10, section: :tools)
        |> Winnow.render()

      contents = Enum.map(result.messages, & &1.content)
      # Each section has budget 15: only high-priority piece fits in each
      assert "M1" in contents
      assert "T1" in contents
      refute "M2" in contents
      refute "T2" in contents
    end

    test "sequence ordering preserved across sections" do
      result =
        Winnow.new(budget: 200)
        |> Winnow.section(:memory, max_tokens: 50)
        |> Winnow.add(:system, priority: 1000, content: "First", token_count: 5)
        |> Winnow.add(:user, priority: 1000, content: "Second", token_count: 5, section: :memory)
        |> Winnow.add(:user, priority: 1000, content: "Third", token_count: 5)
        |> Winnow.render()

      contents = Enum.map(result.messages, & &1.content)
      assert contents == ["First", "Second", "Third"]
    end
  end

  describe "render/1 — tools" do
    test "RenderResult.tools contains tool maps for included tools" do
      tools = [
        %{name: "search", description: "Search the web"},
        %{name: "weather", description: "Get weather"}
      ]

      result =
        Winnow.new(budget: 1000)
        |> Winnow.add_tools(tools, priority: 750)
        |> Winnow.render()

      assert [_, _] = result.tools
      names = Enum.map(result.tools, & &1.name)
      assert "search" in names
      assert "weather" in names
    end

    test "dropped tools excluded from RenderResult.tools" do
      tools = [
        %{name: "search", description: "Search the web"},
        %{name: "weather", description: "Get weather"}
      ]

      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:system, priority: 1000, content: "System", token_count: 10)
        |> Winnow.add_tools(tools, priority: 100)
        |> Winnow.render()

      # Budget too tight for tools at low priority — they get dropped
      assert result.tools == []
    end

    test "empty when no tools added" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 500, content: "Hello", token_count: 5)
        |> Winnow.render()

      assert result.tools == []
    end
  end

  describe "render/1 — truncation uses tokenizer overhead" do
    defmodule LowOverheadTokenizer do
      @behaviour Winnow.Tokenizer

      @impl true
      def count_tokens(text), do: div(byte_size(text), 4)

      @impl true
      def message_overhead, do: 2
    end

    test "truncation uses tokenizer overhead, not hardcoded 4" do
      # With overhead=2 and budget=12, available for content = 12-2 = 10 tokens = 40 bytes
      # With hardcoded overhead=4, available would be 12-4 = 8 tokens = 32 bytes
      content = String.duplicate("x", 160)

      result =
        Winnow.new(budget: 12, tokenizer: LowOverheadTokenizer)
        |> Winnow.add(:user,
          priority: 1000,
          content: content,
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert result.total_tokens == 12
      [piece] = result.included
      # With overhead=2: 10 tokens for content. div(byte_size, 4) <= 10 allows
      # up to 43 bytes; hardcoded overhead 4 would allow at most 35.
      assert byte_size(piece.content) == 43
      assert piece.token_count == 12
    end
  end

  defmodule ZeroOverheadByteTokenizer do
    @moduledoc false
    @behaviour Winnow.Tokenizer

    @impl true
    def count_tokens(text), do: byte_size(text)

    @impl true
    def message_overhead, do: 0
  end

  describe "render/1 — truncation with byte-per-token tokenizer" do
    defmodule ByteTokenizer do
      @behaviour Winnow.Tokenizer

      @impl true
      def count_tokens(text), do: byte_size(text)

      @impl true
      def message_overhead, do: 2
    end

    test "truncation respects non-standard tokenizer ratio" do
      # ByteTokenizer: 1 byte = 1 token, overhead = 2. Budget 15 leaves 13
      # content tokens = 13 bytes (a 4 bytes/token guess would overshoot).
      result =
        Winnow.new(budget: 15, tokenizer: ByteTokenizer)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("x", 100),
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert result.total_tokens == 15
      [piece] = result.included
      assert piece.token_count == 15
      assert byte_size(piece.content) == 13
    end
  end

  describe "render/1 — cache_breakpoint" do
    test "nil when no cacheable pieces" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "Hello", token_count: 10)
        |> Winnow.render()

      assert result.cache_breakpoint == nil
    end

    test "all cacheable — breakpoint is last message index" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "A", token_count: 5, cacheable: true)
        |> Winnow.add(:user, priority: 1000, content: "B", token_count: 5, cacheable: true)
        |> Winnow.add(:user, priority: 1000, content: "C", token_count: 5, cacheable: true)
        |> Winnow.render()

      assert result.cache_breakpoint == 2
    end

    test "cacheable at start, non-cacheable after" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "Sys", token_count: 5, cacheable: true)
        |> Winnow.add(:system, priority: 1000, content: "Tools", token_count: 5, cacheable: true)
        |> Winnow.add(:user, priority: 900, content: "Task", token_count: 5)
        |> Winnow.render()

      assert result.cache_breakpoint == 1
    end

    test "cacheable piece with empty content (reservation) is skipped" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "Hello", token_count: 5, cacheable: true)
        |> Winnow.reserve(:response, tokens: 10)
        |> Winnow.add(:user, priority: 900, content: "Task", token_count: 5)
        |> Winnow.render()

      # Reserve has empty content, not in messages. Breakpoint is index 0 (Hello).
      assert result.cache_breakpoint == 0
      assert [_, _] = result.messages
    end

    test "non-contiguous cacheable pieces — breakpoint at last cacheable message" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "A", token_count: 5, cacheable: true)
        |> Winnow.add(:user, priority: 1000, content: "B", token_count: 5)
        |> Winnow.add(:user, priority: 1000, content: "C", token_count: 5, cacheable: true)
        |> Winnow.add(:user, priority: 1000, content: "D", token_count: 5)
        |> Winnow.render()

      # Messages: A(0), B(1), C(2), D(3). Last cacheable = C at index 2.
      assert result.cache_breakpoint == 2
    end

    test "cacheable piece dropped by priority — no breakpoint" do
      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:system, priority: 1000, content: "Sys", token_count: 10)
        |> Winnow.add(:user, priority: 100, content: "Cache me", token_count: 10, cacheable: true)
        |> Winnow.render()

      # Cacheable piece dropped because low priority
      assert result.cache_breakpoint == nil
    end
  end

  describe "render/1 — binary search / fallback imprecision" do
    test "fallback used when primary fits by threshold but not by greedy budget" do
      # A: primary=15, fallback="aa" (~4 tokens)
      # B: primary=10, fallback="bb" (~4 tokens)
      # Budget=19. Binary search min costs: A=4, B=4 → 8, fits at p500.
      # Greedy: A primary=15, fits (remaining=4). B primary=10>4.
      # B fallback "bb" = div(2,4)+4 = 4 tokens. 4 <= 4? Yes!
      result =
        Winnow.new(budget: 19)
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("a", 60),
          token_count: 15,
          fallbacks: ["aa"]
        )
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("b", 40),
          token_count: 10,
          fallbacks: ["bb"]
        )
        |> Winnow.render()

      assert result.total_tokens == 19
      assert [_, _] = result.included
      assert [_] = result.fallbacks_used
      {fb_piece, 0} = hd(result.fallbacks_used)
      assert fb_piece.content == String.duplicate("b", 40)
    end
  end

  describe "render/1 — truncation edge cases" do
    test "conjuncts in any script the Unicode tables cover stay whole" do
      # Myanmar, Sinhala, Khmer conjunct runs (consonant + virama + consonant)
      for {name, unit, cons} <- [
            {"Myanmar", "က္", "က"},
            {"Sinhala", "ක්\u200D", "ක"},
            {"Khmer", "ក្", "ក"},
            {"Devanagari", "क्", "क"}
          ],
          budget <- [20, 34, 60] do
        content = "a" <> String.duplicate(unit, 30) <> cons <> String.duplicate("z", 400)

        result =
          Winnow.new(budget: budget)
          |> Winnow.add(:user, priority: 1, content: content, overflow: :truncate_end)
          |> Winnow.render()

        for %{content: cut} <- result.messages do
          g = String.graphemes(cut)

          assert g == Enum.take(String.graphemes(content), length(g)),
                 "#{name} split at #{budget}"
        end
      end
    end

    test "vowel-sign and ZWJ runs truncate quickly" do
      for content <- [String.duplicate("का", 100_000), String.duplicate("a\u200D", 150_000)],
          mode <- [:truncate_end, :truncate_middle] do
        {micros, result} =
          :timer.tc(fn ->
            Winnow.new(budget: 5000)
            |> Winnow.add(:user, priority: 1, content: content, overflow: mode)
            |> Winnow.render()
          end)

        assert [_] = result.messages
        assert micros < 500_000
      end
    end

    test ":truncate_middle output never shrinks as the budget grows" do
      e41 = "e" <> String.duplicate("\u0301", 20)
      e61 = "e" <> String.duplicate("\u0301", 30)
      content = "a" <> e41 <> String.duplicate("m", 30) <> e61 <> "z"

      sizes =
        for budget <- 12..40 do
          result =
            Winnow.new(budget: budget)
            |> Winnow.add(:user, priority: 1, content: content, overflow: :truncate_middle)
            |> Winnow.render()

          result.messages |> Enum.map(&byte_size(&1.content)) |> Enum.sum()
        end

      assert sizes == Enum.sort(sizes)
      assert List.last(sizes) == byte_size(content)
    end

    test "a truncatable :infinity piece that can't fit raises rather than vanishing" do
      assert_raise Winnow.OversizedContentError, ~r/smallest truncation/, fn ->
        Winnow.new(budget: 3)
        |> Winnow.add(:system,
          priority: :infinity,
          content: "You are a helpful assistant",
          overflow: :truncate_end
        )
        |> Winnow.render()
      end
    end

    test ":truncate_middle keeps both sides even when the first grapheme is large" do
      content = "👨‍👩‍👧‍👦" <> String.duplicate("a", 100)

      result =
        Winnow.new(budget: 40, tokenizer: __MODULE__.ByteTokenizer)
        |> Winnow.add(:user, priority: 1, content: content, overflow: :truncate_middle)
        |> Winnow.render()

      [%{content: truncated}] = result.messages
      # 40 - 2 overhead = 38 bytes: the 25-byte family emoji, the 7-byte
      # marker, and 6 bytes of suffix
      assert truncated == "👨‍👩‍👧‍👦 [...] aaaaaa"
      assert result.total_tokens == 40
    end

    test "empty content can't claim a free truncation" do
      # token_count 4 is its only real form; it must not be costed at 0 and
      # then lose its place to a lower-priority piece.
      result =
        Winnow.new(budget: 10)
        |> Winnow.add(:user,
          priority: 10,
          content: "",
          token_count: 4,
          overflow: :truncate_end,
          name: :hi
        )
        |> Winnow.add(:user, priority: 5, content: String.duplicate("b", 24), name: :lo)
        |> Winnow.render()

      assert Enum.map(result.included, & &1.name) == [:hi]
    end

    test "skin-tone emoji runs truncate quickly and whole" do
      content = String.duplicate("👍🏽", 50_000)

      {micros, result} =
        :timer.tc(fn ->
          Winnow.new(budget: 500)
          |> Winnow.add(:user, priority: 1, content: content, overflow: :truncate_middle)
          |> Winnow.render()
        end)

      [%{content: truncated}] = result.messages
      kept = String.replace(truncated, " [...] ", "")
      assert Enum.all?(String.graphemes(kept), &(&1 == "👍🏽"))
      assert micros < 500_000
    end

    test "flag emoji are never split, even in runs longer than the boundary window" do
      flags = String.duplicate("🇺🇸", 40)

      for budget <- [20, 30, 40], mode <- [:truncate_end, :truncate_middle] do
        result =
          Winnow.new(budget: budget)
          |> Winnow.add(:user, priority: 1, content: flags, overflow: mode)
          |> Winnow.render()

        [%{content: content}] = result.messages
        kept = String.replace(content, " [...] ", "")
        assert rem(byte_size(kept), 8) == 0, "split flag at budget #{budget}, #{mode}"
        assert Enum.all?(String.graphemes(kept), &(&1 == "🇺🇸"))
      end
    end

    test "untruncatable explicit-count piece doesn't make higher priorities downgrade" do
      # The placeholder can't be truncated honestly (tokenizer sees ~3 tokens,
      # caller says 1000), so nothing is reserved for it and the system prompt
      # keeps its primary.
      result =
        Winnow.new(budget: 30)
        |> Winnow.add(:system, priority: 100, content: "big", token_count: 27, fallbacks: ["sm"])
        |> Winnow.add(:user,
          priority: 1,
          content: "<image ref>",
          token_count: 1000,
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert Enum.map(result.messages, & &1.content) == ["big"]
      assert result.fallbacks_used == []
    end

    test "explicit token_count that disagrees with the content isn't 'truncated' into a lie" do
      # The tokenizer thinks "<image ref>" is tiny; the caller says 1000.
      # Truncation can't shrink what's already short, so the piece is dropped
      # instead of being reported at the tokenizer's 6 tokens.
      result =
        Winnow.new(budget: 50)
        |> Winnow.add(:user,
          priority: 1,
          content: "<image ref>",
          token_count: 1000,
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert result.included == []
      assert result.total_tokens == 0
      assert [%{token_count: 1000}] = result.dropped
    end

    test "truncate_middle on large multi-byte content stays valid UTF-8 and in budget" do
      content = String.duplicate("héllo wörld 👋🏽 ", 20_000)

      result =
        Winnow.new(budget: 200)
        |> Winnow.add(:user, priority: 1, content: content, overflow: :truncate_middle)
        |> Winnow.render()

      assert [%{content: truncated}] = result.messages
      assert result.total_tokens == 200
      assert String.valid?(truncated)
      assert truncated =~ " [...] "
      assert String.starts_with?(truncated, "héllo")
      # Suffix ends on a whole grapheme cluster (skin-tone emoji kept intact)
      assert String.ends_with?(truncated, "👋🏽 ")
    end

    test "truncate with remaining = overhead exactly — keeps what costs zero tokens" do
      # Budget = 4 (just overhead). Approximate counts 1-3 bytes as 0 tokens,
      # so the smallest truncation fits and the piece keeps real content.
      result =
        Winnow.new(budget: 4)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("x", 100),
          overflow: :truncate_end,
          metadata: {:story, 41}
        )
        |> Winnow.render()

      assert result.total_tokens == 4
      assert [%{content: "xxx"}] = result.messages
      assert [%{metadata: {:story, 41}}] = result.included
    end

    test "truncatable piece with no room for content is dropped, not included empty" do
      # 1 token per byte, overhead 2: the smallest truncation ("x") costs 3.
      # At budget 2 only the overhead fits, so there's no room for content.
      result =
        Winnow.new(budget: 2, tokenizer: __MODULE__.ByteTokenizer)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("x", 100),
          overflow: :truncate_end,
          metadata: {:story, 41}
        )
        |> Winnow.render()

      assert result.total_tokens == 0
      assert result.included == []
      assert [%{metadata: {:story, 41}}] = result.dropped
    end

    test "truncate_middle at its tightest budget keeps content on both sides" do
      # Smallest middle form is "s [...] s" (9 bytes = 2 tokens + 4 overhead).
      render = fn budget ->
        Winnow.new(budget: budget)
        |> Winnow.add(:system, priority: 100, content: "sys", token_count: 10)
        |> Winnow.add(:user,
          priority: 1,
          content: String.duplicate("s", 400),
          overflow: :truncate_middle
        )
        |> Winnow.render()
      end

      # One token short: the piece is dropped rather than emitting a bare or
      # one-sided marker
      assert Enum.map(render.(15).messages, & &1.content) == ["sys"]
      assert Enum.map(render.(16).messages, & &1.content) == ["sys", "ss [...] ss"]
    end

    test "content too short to middle-truncate is kept whole or dropped, never mangled" do
      # "ab" can't carry " [...] " with content on both sides in fewer bytes
      # than itself, so its only form is the primary (2 bytes + 2 overhead).
      render = fn budget ->
        Winnow.new(budget: budget, tokenizer: __MODULE__.ByteTokenizer)
        |> Winnow.add(:user, priority: 1, content: "ab", overflow: :truncate_middle)
        |> Winnow.render()
      end

      assert %{messages: [], dropped: [%{content: "ab"}]} = render.(3)
      assert %{messages: [%{content: "ab"}], total_tokens: 4} = render.(4)
    end

    test "truncate_end with full budget consumed — piece excluded by threshold" do
      # Reserve takes the full budget (10). Truncatable piece's min cost is
      # overhead (4). 10 + 4 = 14 > 10, so threshold excludes the truncatable piece.
      result =
        Winnow.new(budget: 10)
        |> Winnow.reserve(:response, tokens: 10)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("x", 100),
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert result.total_tokens == 10
      assert [_] = result.included
      assert hd(result.included).name == :response
      assert [_] = result.dropped
    end
  end

  describe "render/1 — priority edge cases" do
    test "all pieces :infinity — threshold is 0, all included" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: :infinity, content: "A", token_count: 10)
        |> Winnow.add(:user, priority: :infinity, content: "B", token_count: 10)
        |> Winnow.render()

      assert result.threshold == 0
      assert [_, _] = result.included
      assert result.dropped == []
    end

    test "budget = 1 with piece overhead > 1 — rejected at admission" do
      # Approximate: "x" → div(1, 4) + 4 = 4 tokens > budget 1.
      result =
        Winnow.new(budget: 1)
        |> Winnow.add(:user, priority: 1000, content: "x")
        |> Winnow.render()

      assert result.messages == []
      assert [%{content: "x"}] = result.dropped
      assert result.threshold == 1001
    end

    test "mix of :infinity and regular priorities" do
      result =
        Winnow.new(budget: 25)
        |> Winnow.add(:system, priority: :infinity, content: "Always", token_count: 10)
        |> Winnow.add(:user, priority: 1000, content: "High", token_count: 10)
        |> Winnow.add(:user, priority: 100, content: "Low", token_count: 10)
        |> Winnow.render()

      # Budget 25: infinity(10) + 1000(10) = 20 fits. Adding 100 = 30 > 25.
      contents = Enum.map(result.messages, & &1.content)
      assert "Always" in contents
      assert "High" in contents
      refute "Low" in contents
    end
  end

  describe "render/1 — section edge cases" do
    test "a section doesn't spend its room on a piece the budget can't hold" do
      # A (16 tokens, omittable) never fits the budget of 10. Growing the
      # section enough to admit A must not push P out in favour of L.
      render = fn max_tokens ->
        Winnow.new(budget: 10)
        |> Winnow.section(:s, max_tokens: max_tokens)
        |> Winnow.add(:user,
          priority: 2,
          content: String.duplicate("a", 48),
          fallbacks: [""],
          section: :s
        )
        |> Winnow.add(:user, priority: 1, content: "pppp", section: :s)
        |> Winnow.add(:user, priority: 0, content: String.duplicate("l", 24))
        |> Winnow.render()
      end

      for max_tokens <- [15, 16, 100] do
        assert Enum.map(render.(max_tokens).messages, & &1.content) == ["pppp"]
      end
    end

    test "a section whose level overflows closes; the rest of the prompt carries on" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.section(:s, max_tokens: 10)
        |> Winnow.add(:user, priority: 5, content: "big", token_count: 20, section: :s)
        |> Winnow.add(:user, priority: 4, content: "small", token_count: 5, section: :s)
        |> Winnow.add(:user, priority: 3, content: "main", token_count: 30)
        |> Winnow.render()

      assert Enum.map(result.messages, & &1.content) == ["main"]
      assert Enum.map(result.dropped, & &1.content) |> Enum.sort() == ["big", "small"]
      assert result.threshold == 3
    end

    test "a section's fallback choice is a cap, not a commitment" do
      # The section can afford fallback 0 ("b" x 40), but the main budget can
      # only afford fallback 1 ("c"); the main pass must still be able to pick it.
      for priority <- [10, :infinity] do
        result =
          Winnow.new(budget: 5)
          |> Winnow.section(:s, max_tokens: 100)
          |> Winnow.add(:user,
            priority: priority,
            content: String.duplicate("a", 400),
            fallbacks: [String.duplicate("b", 40), "c"],
            section: :s
          )
          |> Winnow.render()

        assert [%{content: "c"}] = result.messages
        assert [{%{content: "aaaa" <> _}, 1}] = result.fallbacks_used
      end
    end

    test "re-truncating in the main pass never cuts into an earlier marker" do
      # The fuzzer's case: 1 token/byte, no overhead. Previously rendered
      # " [.. [...] aaaa"; now the only honest forms don't fit, so it drops.
      content = "👨‍👩‍👧‍👦" <> String.duplicate("a", 100)

      result =
        Winnow.new(budget: 15, tokenizer: __MODULE__.ZeroOverheadByteTokenizer)
        |> Winnow.section(:s, max_tokens: 40)
        |> Winnow.add(:user,
          priority: 1,
          content: content,
          overflow: :truncate_middle,
          section: :s
        )
        |> Winnow.render()

      # Smallest middle form is 25 + 7 + 1 = 33 bytes > 15
      assert result.messages == []
      assert [%{content: ^content}] = result.dropped
      assert result.total_tokens == 0
    end

    test "section and main pass truncate once, from the original" do
      content = "👨‍👩‍👧‍👦" <> String.duplicate("a", 100)

      result =
        Winnow.new(budget: 60, tokenizer: __MODULE__.ByteTokenizer)
        |> Winnow.section(:s, max_tokens: 80)
        |> Winnow.add(:user,
          priority: 1,
          content: content,
          overflow: :truncate_middle,
          section: :s
        )
        |> Winnow.render()

      [%{content: truncated}] = result.messages
      assert [prefix, suffix] = String.split(truncated, " [...] ")
      refute suffix =~ "["
      assert String.starts_with?(content, prefix)
      assert String.ends_with?(content, suffix)
    end

    test "identical pieces each keep their own fallback bookkeeping" do
      piece_opts = [
        priority: 5,
        content: String.duplicate("x", 400),
        fallbacks: ["shrt"],
        overflow: :truncate_end,
        sequence: 5,
        section: :s
      ]

      # Min cost per piece is 4 (smallest truncation); budget 9 admits both.
      # The first takes its fallback (5), the second a truncation (4).
      result =
        Winnow.new(budget: 9)
        |> Winnow.section(:s, max_tokens: 100)
        |> Winnow.add(:user, piece_opts)
        |> Winnow.add(:user, piece_opts)
        |> Winnow.render()

      assert Enum.map(result.included, & &1.content) |> Enum.sort() == ["shrt", "xxx"]
      assert [{%{content: "xxxx" <> _}, 0}] = result.fallbacks_used
      assert result.total_tokens == 9
    end

    test "identical :infinity pieces that can't both fit raise instead of vanishing" do
      piece_opts = [
        priority: :infinity,
        content: String.duplicate("x", 400),
        overflow: :truncate_end
      ]

      assert_raise Winnow.OversizedContentError, ~r/smallest truncation/, fn ->
        Winnow.new(budget: 6)
        |> Winnow.add(:user, piece_opts)
        |> Winnow.add(:user, piece_opts)
        |> Winnow.render()
      end
    end

    test ":infinity piece over its section cap raises naming the section" do
      error =
        assert_raise Winnow.OversizedContentError, fn ->
          Winnow.new(budget: 10_000)
          |> Winnow.section(:memory, max_tokens: 5)
          |> Winnow.add(:user,
            priority: :infinity,
            content: String.duplicate("x", 100),
            section: :memory
          )
          |> Winnow.render()
        end

      assert error.section == :memory
      assert Exception.message(error) =~ "in section :memory"
    end

    test "section fallback not reported when main pass drops the piece" do
      result =
        Winnow.new(budget: 10)
        |> Winnow.section(:memory, max_tokens: 10)
        |> Winnow.add(:user,
          priority: 10,
          content: "big",
          token_count: 20,
          fallbacks: ["tiny"],
          section: :memory
        )
        |> Winnow.add(:system, priority: 100, content: "sys", token_count: 10)
        |> Winnow.render()

      assert [%{content: "sys"}] = result.messages
      # Dropped pieces are reported in their original form, not the section's
      # resolved fallback
      assert [%{content: "big", fallbacks: ["tiny"]}] = result.dropped
      assert result.fallbacks_used == []
    end

    test "section max_tokens > main budget — section respects its own budget" do
      result =
        Winnow.new(budget: 20)
        |> Winnow.section(:big, max_tokens: 1000)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Sec",
          token_count: 10,
          section: :big
        )
        |> Winnow.add(:system, priority: 1000, content: "Main", token_count: 10)
        |> Winnow.render()

      # Section piece (10) fits within section budget (1000).
      # Then main pass: section piece (10) + main piece (10) = 20 = budget.
      assert result.total_tokens == 20
      contents = Enum.map(result.messages, & &1.content)
      assert "Sec" in contents
      assert "Main" in contents
    end

    test "piece assigned to undeclared section — treated as main piece" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Orphan",
          token_count: 10,
          section: :nonexistent
        )
        |> Winnow.render()

      assert [%{content: "Orphan"}] = result.messages
      assert result.total_tokens == 10
    end

    test "section with zero max_tokens — all section pieces dropped" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.section(:empty, max_tokens: 0)
        |> Winnow.add(:user,
          priority: 1000,
          content: "Doomed",
          token_count: 10,
          section: :empty
        )
        |> Winnow.add(:system, priority: 1000, content: "Main", token_count: 10)
        |> Winnow.render()

      contents = Enum.map(result.messages, & &1.content)
      refute "Doomed" in contents
      assert "Main" in contents
    end
  end

  describe "render/1 — fallback edge cases" do
    test "threshold when the top level holds only omittable pieces" do
      # The level's (empty) mandatory set fits, so it counts as admitted even
      # though its one piece is skipped.
      result =
        Winnow.new(budget: 10)
        |> Winnow.add(:user, priority: 100, content: "big", token_count: 50, fallbacks: [""])
        |> Winnow.render()

      assert result.included == []
      assert result.threshold == 100
    end

    test "omission never makes room for a lower-priority piece" do
      for budget <- [100, 101, 150] do
        result =
          Winnow.new(budget: budget, tokenizer: __MODULE__.ByteTokenizer)
          |> Winnow.add(:user, priority: 10, content: String.duplicate("a", 98), fallbacks: [""])
          |> Winnow.add(:user, priority: 5, content: String.duplicate("b", 99))
          |> Winnow.render()

        assert [%{priority: 10}] = result.included, "budget #{budget}"
      end
    end

    test "an omittable piece that doesn't fit doesn't block lower levels" do
      result =
        Winnow.new(budget: 20)
        |> Winnow.add(:user, priority: 10, content: "huge", token_count: 500, fallbacks: [""])
        |> Winnow.add(:user, priority: 5, content: "small", token_count: 10)
        |> Winnow.render()

      assert [%{content: "small"}] = result.messages
      assert [%{content: "huge"}] = result.dropped
    end

    test "empty fallback costs nothing — no priority inversion" do
      # The optional piece can always be omitted, so the high-priority piece
      # keeps its primary instead of downgrading to make room for nothing.
      result =
        Winnow.new(budget: 24)
        |> Winnow.add(:system, priority: 100, content: "big", token_count: 22, fallbacks: ["sm"])
        |> Winnow.add(:user, priority: 1, content: "opt", token_count: 50, fallbacks: [""])
        |> Winnow.render()

      assert Enum.map(result.messages, & &1.content) == ["big"]
      assert result.fallbacks_used == []
      assert [%{content: "opt"}] = result.dropped
    end

    test "empty-string fallback means omit — piece reported as dropped" do
      result =
        Winnow.new(budget: 14)
        |> Winnow.add(:system, priority: 100, content: "sys", token_count: 10)
        |> Winnow.add(:user,
          priority: 1,
          content: "long",
          token_count: 50,
          fallbacks: [String.duplicate("s", 40), ""]
        )
        |> Winnow.render()

      assert Enum.map(result.messages, & &1.content) == ["sys"]
      assert [%{content: "long"}] = result.dropped
      assert result.fallbacks_used == []
      assert result.total_tokens == 10
    end

    test "fallback larger than primary — primary used since it fits" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 500,
          content: "X",
          token_count: 5,
          fallbacks: [String.duplicate("y", 200)]
        )
        |> Winnow.render()

      assert [%{content: "X"}] = result.messages
      assert result.fallbacks_used == []
    end

    test "multiple fallbacks where only middle one fits" do
      # Primary too large, first fallback too large, second fits, third too large.
      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:system, priority: 1000, content: "Sys", token_count: 10)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("a", 200),
          token_count: 50,
          fallbacks: [
            String.duplicate("b", 200),
            "ok",
            String.duplicate("c", 200)
          ]
        )
        |> Winnow.render()

      # Remaining after Sys = 5. Primary = 50, fb0 = 54, fb1 "ok" = div(2, 4) + 4 = 4
      # fits, fb2 isn't reached.
      assert Enum.map(result.messages, & &1.content) == ["Sys", "ok"]
      assert [{%{token_count: 50}, 1}] = result.fallbacks_used
      assert result.total_tokens == 14
    end
  end

  describe "render/1 — tightened assertions" do
    test "two pieces exact token count" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "A", token_count: 10)
        |> Winnow.add(:user, priority: 500, content: "B", token_count: 15)
        |> Winnow.render()

      assert result.total_tokens == 25
    end

    test "reserve + piece exact total" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.reserve(:response, tokens: 50)
        |> Winnow.add(:system, priority: 1000, content: "A", token_count: 10)
        |> Winnow.render()

      assert result.total_tokens == 60
    end

    test "section piece exact token count" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.section(:mem, max_tokens: 50)
        |> Winnow.add(:user, priority: 1000, content: "M", token_count: 8, section: :mem)
        |> Winnow.add(:system, priority: 1000, content: "S", token_count: 12)
        |> Winnow.render()

      assert result.total_tokens == 20
    end
  end

  describe "render/1 — greedy pass respects priority and pending minimums" do
    test "truncatable piece before a reservation does not starve it" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 10,
          content: String.duplicate("a", 800),
          overflow: :truncate_end
        )
        |> Winnow.reserve(:response, tokens: 50)
        |> Winnow.render()

      # 100 - 50 reserved - 4 overhead = 46 content tokens = 187 bytes
      assert result.total_tokens == 100
      assert [%{content: content}] = result.messages
      assert content == String.duplicate("a", 187)
      assert Enum.any?(result.included, &(&1.name == :response))
      assert result.dropped == []
    end

    test "low-priority earlier piece yields to high-priority later piece" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 10,
          content: String.duplicate("b", 224),
          fallbacks: ["short"]
        )
        |> Winnow.add(:user, priority: 20, content: String.duplicate("c", 224))
        |> Winnow.render()

      # 60 + "short" (1 + 4)
      assert result.total_tokens == 65
      assert [_, %{content: "short"}] = result.included |> Enum.sort_by(&(-&1.priority))
      assert [{%{priority: 10}, 0}] = result.fallbacks_used
      # Output still ordered by sequence
      assert [%{content: "short"}, _] = result.messages
    end

    test "high-priority truncatable piece leaves room for lower-priority fixed piece" do
      fixed = String.duplicate("d", 64)

      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:user,
          priority: 20,
          content: String.duplicate("a", 800),
          overflow: :truncate_end
        )
        |> Winnow.add(:user, priority: 10, content: fixed)
        |> Winnow.render()

      assert result.total_tokens == 100
      assert Enum.any?(result.messages, &(&1.content == fixed))
    end

    test "spare budget upgrades the highest-priority piece first" do
      # Both min costs are 5 (fallback "tiny"); budget only allows one primary.
      result =
        Winnow.new(budget: 30)
        |> Winnow.add(:user, priority: 1, content: "low", token_count: 20, fallbacks: ["tiny"])
        |> Winnow.add(:user, priority: 2, content: "high", token_count: 20, fallbacks: ["tiny"])
        |> Winnow.render()

      assert Enum.map(result.messages, & &1.content) == ["tiny", "high"]
    end
  end

  # Generators for property tests

  defp piece_generator do
    gen all(
          priority <-
            frequency([
              {9, integer(1..1000)},
              {1, constant(:infinity)}
            ]),
          content_size <- integer(1..400),
          cacheable <- frequency([{4, constant(false)}, {1, constant(true)}]),
          fallback <-
            frequency([
              {3, constant(nil)},
              {1, string(:alphanumeric, min_length: 1, max_length: 50)}
            ])
        ) do
      {priority, String.duplicate("x", content_size), cacheable, fallback}
    end
  end

  # May `winner` take `loser`'s place when room grows? Higher priority, or at
  # the same priority: a non-omittable piece over an omittable one (levels
  # admit those first), else the earlier sequence.
  defp outranks?(winner, loser) do
    omittable? = &("" in &1.fallbacks)

    cond do
      winner.priority != loser.priority -> winner.priority > loser.priority
      omittable?.(winner) != omittable?.(loser) -> omittable?.(loser)
      true -> winner.sequence < loser.sequence
    end
  end

  # Mixes :error pieces (with and without fallbacks) with truncatable ones.
  defp mixed_piece_generator do
    gen all(
          priority <- integer(1..100),
          content <-
            one_of([
              map(integer(0..400), &String.duplicate("x", &1)),
              string(:printable, max_length: 300)
            ]),
          overflow <- member_of([:error, :truncate_end, :truncate_middle]),
          fallbacks <- list_of(string(:alphanumeric, max_length: 40), max_length: 2)
        ) do
      [
        priority: priority,
        content: content,
        overflow: overflow,
        fallbacks: fallbacks
      ]
    end
  end

  defp build_winnow(budget, pieces) do
    pieces
    |> Enum.with_index()
    |> Enum.reduce(Winnow.new(budget: budget), fn {{priority, content, cacheable, fallback}, _idx},
                                                  w ->
      opts = [
        priority: priority,
        content: content,
        overflow: :truncate_end,
        cacheable: cacheable
      ]

      # :infinity pieces must not vanish, so an unfittable one raises; make
      # the generated ones omittable so these properties test the budget pass.
      fallbacks =
        [fallback, if(priority == :infinity, do: "")]
        |> Enum.reject(&is_nil/1)

      opts = if fallbacks != [], do: Keyword.put(opts, :fallbacks, fallbacks), else: opts
      Winnow.add(w, :user, opts)
    end)
  end
end
