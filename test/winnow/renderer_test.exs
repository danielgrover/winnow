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
        w = build_winnow(budget, pieces)
        result = Winnow.render(w)
        assert result.total_tokens <= result.budget
      end
    end

    property "all included pieces have priority >= threshold" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 1, max_length: 20)
            ) do
        w = build_winnow(budget, pieces)
        result = Winnow.render(w)

        for piece <- result.included do
          assert piece.priority == :infinity or piece.priority >= result.threshold
        end
      end
    end

    property "all dropped pieces have priority < threshold" do
      check all(
              budget <- integer(1..1000),
              pieces <- list_of(piece_generator(), min_length: 1, max_length: 20)
            ) do
        w = build_winnow(budget, pieces)
        result = Winnow.render(w)

        for piece <- result.dropped do
          assert piece.priority < result.threshold
        end
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
      flag = :persistent_term.put({__MODULE__, :cond_flag}, false)

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
      _ = flag
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

  # Generators for property tests

  defp piece_generator do
    gen all(
          priority <- integer(1..1000),
          token_count <- integer(1..100)
        ) do
      {priority, token_count}
    end
  end

  defp build_winnow(budget, pieces) do
    pieces
    |> Enum.with_index()
    |> Enum.reduce(Winnow.new(budget: budget), fn {{priority, token_count}, _idx}, w ->
      Winnow.add(w, :user, priority: priority, content: "x", token_count: token_count)
    end)
  end
end
