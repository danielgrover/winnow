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
      # Threshold should be above 500 so the piece is excluded
      assert Renderer.find_threshold(pieces, 100, @tokenizer) > 500
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

      # All same priority — all included or all excluded
      assert Renderer.find_threshold(pieces, 100, @tokenizer) == 500
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
      assert length(result.included) == 1
      assert result.dropped == []
    end

    test "drops low-priority piece when over budget" do
      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:system, priority: 1000, content: "Important", token_count: 10)
        |> Winnow.add(:user, priority: 100, content: "Less important", token_count: 10)
        |> Winnow.render()

      assert length(result.messages) == 1
      assert [%{role: :system, content: "Important"}] = result.messages
      assert result.total_tokens == 10
      assert length(result.included) == 1
      assert length(result.dropped) == 1
      assert hd(result.dropped).priority == 100
    end

    test "zero budget drops everything except reservations" do
      result =
        Winnow.new(budget: 0)
        |> Winnow.add(:system, priority: 1000, content: "Hello", token_count: 10)
        |> Winnow.render()

      assert result.messages == []
      assert result.total_tokens == 0
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
      assert length(result.included) == 2
      assert length(result.dropped) == 1

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
      assert length(result.messages) == 1
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
      assert length(result.fallbacks_used) == 1
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
      # A has a small fallback making binary search include the level.
      # B's primary and fallback are both too large for remaining budget.
      # B has empty content so overflow :error drops it instead of raising.
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
          content: "",
          token_count: 12,
          fallbacks: [String.duplicate("x", 100)]
        )
        |> Winnow.render()

      # A's primary fits (20 <= 25), uses primary. Remaining=5.
      # B primary=12>5, fallback too large, empty content → dropped.
      assert length(result.messages) == 1
    end

    test "fallback preserves role and sequence" do
      result =
        Winnow.new(budget: 15)
        |> Winnow.add(:assistant,
          priority: 500,
          content: "Long response",
          token_count: 20,
          fallbacks: ["Short"]
        )
        |> Winnow.render()

      [msg] = result.messages
      assert msg.role == :assistant
      [piece] = result.included
      assert piece.sequence == 0
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

      contents = Enum.map(result.messages, & &1.content)
      assert "S" in contents
      assert result.fallbacks_used != []
      assert result.total_tokens <= 25
    end
  end

  describe "render/1 — overflow" do
    test ":error raises OversizedContentError for piece above threshold that can't fit" do
      # Piece A has a fallback, so binary search uses min_cost=5.
      # But greedy pass uses A's primary (20) since it fits, leaving only 5 for B.
      # B needs 12, can't fit, has overflow: :error → raises.
      assert_raise Winnow.OversizedContentError, fn ->
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

      assert result.total_tokens <= 30
      assert length(result.messages) == 1
      assert byte_size(hd(result.messages).content) < 200
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

      assert result.total_tokens <= 40
      user_msg = hd(result.messages)
      assert user_msg.content =~ "[...]"
      assert String.starts_with?(user_msg.content, "a")
      assert String.ends_with?(user_msg.content, "z")
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

      assert result.total_tokens <= 30
      user_msg = hd(result.messages)
      assert String.valid?(user_msg.content)
    end

    test "truncation does not exceed budget when remaining < overhead" do
      # Binary search includes A + B (min costs 4+4=8 ≤ 20).
      # Greedy: A uses primary (17), remaining=3. B truncated.
      # Bug: B overhead=4 > remaining 3 → total = 21 > 20.
      result =
        Winnow.new(budget: 20)
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("a", 68),
          token_count: 17,
          fallbacks: ["a"]
        )
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("x", 200),
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert result.total_tokens <= 20
    end
  end

  describe "render/1 — conditions" do
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

      assert length(result.condition_excluded) == 1
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
      contents = Enum.map(result.messages, & &1.content)
      assert "Mem1" in contents
      refute "Mem2" in contents
      assert result.total_tokens <= 100
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

      assert length(result.tools) == 2
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

      assert result.total_tokens <= 12
      [piece] = result.included
      # With overhead=2: available_tokens=10, max_bytes=40
      # Truncated content should be 40 bytes
      assert byte_size(piece.content) == 40
      assert piece.token_count == 12
    end

    test "truncated piece recount uses tokenizer, not div(byte_size, 4)" do
      # Use a tokenizer where count_tokens differs from div(byte_size, 4).
      # With multi-byte chars like "é" (2 bytes each):
      #   div(byte_size, 4) would undercount compared to byte_size / 4
      #   The Approximate tokenizer would give div(byte_size, 4)
      # We use LowOverheadTokenizer (overhead=2, same count_tokens as Approximate)
      # to verify the recount calls count_tokens, not a hardcoded formula.
      content = String.duplicate("x", 200)

      result =
        Winnow.new(budget: 12, tokenizer: LowOverheadTokenizer)
        |> Winnow.add(:user,
          priority: 1000,
          content: content,
          overflow: :truncate_end
        )
        |> Winnow.render()

      [piece] = result.included

      expected_recount =
        LowOverheadTokenizer.count_tokens(piece.content) + LowOverheadTokenizer.message_overhead()

      assert piece.token_count == expected_recount
    end
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
      # ByteTokenizer: 1 byte = 1 token, overhead = 2.
      # Budget=15, content=100 bytes. available=13, but *4 gives max_bytes=52.
      # Truncated to 52 bytes → recount = 52+2 = 54 > 15. Bug!
      result =
        Winnow.new(budget: 15, tokenizer: ByteTokenizer)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("x", 100),
          overflow: :truncate_end
        )
        |> Winnow.render()

      assert result.total_tokens <= 15
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
      assert length(result.messages) == 2
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
    test "binary search optimistic, greedy resolves to fallback" do
      # A: primary=15, fallback="a" (~4 tokens)
      # B: primary=12, fallback="b" (~4 tokens)
      # Budget=20. Binary search min costs: A=min(15,4)=4, B=min(12,4)=4 → 8, fits.
      # Greedy: A primary=15, fits (remaining=5). B primary=12>5.
      # B fallback "b" = div(1,4)+4 = 4 tokens. 4 <= 5? Yes!
      result =
        Winnow.new(budget: 20)
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("a", 60),
          token_count: 15,
          fallbacks: ["a"]
        )
        |> Winnow.add(:user,
          priority: 500,
          content: String.duplicate("b", 48),
          token_count: 12,
          fallbacks: ["b"]
        )
        |> Winnow.render()

      assert result.total_tokens <= 20
      assert length(result.included) == 2
      # B used fallback
      assert result.fallbacks_used != []
      {fb_piece, _idx} = hd(result.fallbacks_used)
      assert fb_piece.content == String.duplicate("b", 48)
    end

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
      assert length(result.included) == 2
      assert length(result.fallbacks_used) == 1
      {fb_piece, 0} = hd(result.fallbacks_used)
      assert fb_piece.content == String.duplicate("b", 40)
    end
  end

  describe "render/1 — truncation edge cases" do
    test "truncate with remaining = overhead exactly — empty content" do
      # Budget = 4 (just overhead for approximate tokenizer).
      # Piece with truncate_end, large content. available_tokens = 4-4 = 0. max_bytes = 0.
      result =
        Winnow.new(budget: 4)
        |> Winnow.add(:user,
          priority: 1000,
          content: String.duplicate("x", 100),
          overflow: :truncate_end
        )
        |> Winnow.render()

      # Truncated to empty content. token_count = count_tokens("") + overhead = 0 + 4 = 4.
      assert result.total_tokens == 4
      # Empty content piece gets excluded from messages by build_messages
      assert result.messages == []
      assert length(result.included) == 1
    end

    test "truncate_middle with content shorter than marker doesn't crash" do
      # Content "ab" = 2 bytes. Marker " [...] " = 7 bytes.
      # Budget allows ~3 tokens content + 4 overhead = ~16 budget needed for full content.
      # Let's force truncation by setting budget low.
      result =
        Winnow.new(budget: 5)
        |> Winnow.add(:user,
          priority: 1000,
          content: "ab",
          overflow: :truncate_middle
        )
        |> Winnow.render()

      assert result.total_tokens <= 5
      [piece] = result.included
      assert String.valid?(piece.content)
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
      assert length(result.included) == 1
      assert hd(result.included).name == :response
      assert length(result.dropped) == 1
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
      assert length(result.included) == 2
      assert result.dropped == []
    end

    test "budget = 1 with piece overhead > 1 — dropped by greedy pass" do
      # Approximate tokenizer: "x" → div(1,4)+4 = 4 tokens. Budget = 1.
      result =
        Winnow.new(budget: 1)
        |> Winnow.add(:user, priority: 1000, content: "x")
        |> Winnow.render()

      # Token count = 4 > budget 1. Threshold should exclude it.
      assert result.messages == []
      assert result.dropped != []
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

      # Remaining after Sys = 5. Primary=50, fb0=large, fb1="ok"=div(2,4)+4=4+1=5, fits!
      contents = Enum.map(result.messages, & &1.content)
      assert "ok" in contents
      assert length(result.fallbacks_used) == 1
      {_piece, index} = hd(result.fallbacks_used)
      assert index == 1
    end
  end

  describe "render/1 — tightened assertions" do
    test "single piece exact token count" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1000, content: "Hello", token_count: 10)
        |> Winnow.render()

      assert result.total_tokens == 10
    end

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

    test "multiple pieces with fallbacks — exact total" do
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

      # S=5. Greedy: A primary=15, fits (remaining=20). B primary=15>5.
      # B fallback "B" = div(1,4)+4 = 0+4 = 4. Fits!
      # Total: 5 + 15 + 4 = 24.
      assert result.total_tokens == 24
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
          content_size <- integer(1..400)
        ) do
      {priority, String.duplicate("x", content_size)}
    end
  end

  defp build_winnow(budget, pieces) do
    pieces
    |> Enum.with_index()
    |> Enum.reduce(Winnow.new(budget: budget), fn {{priority, content}, _idx}, w ->
      Winnow.add(w, :user, priority: priority, content: content, overflow: :truncate_end)
    end)
  end
end
