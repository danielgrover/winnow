defmodule WinnowTest do
  use ExUnit.Case, async: true

  describe "new/1" do
    test "creates with budget and default tokenizer" do
      w = Winnow.new(budget: 4000)
      assert w.budget == 4000
      assert w.tokenizer == Winnow.Tokenizer.Approximate
      assert w.pieces == []
      assert w.next_sequence == 0
    end

    test "accepts custom tokenizer" do
      w = Winnow.new(budget: 4000, tokenizer: Winnow.Tokenizer.Approximate)
      assert w.tokenizer == Winnow.Tokenizer.Approximate
    end

    test "raises without budget" do
      assert_raise KeyError, fn ->
        Winnow.new([])
      end
    end
  end

  describe "add/3" do
    test "adds piece with correct role, priority, content" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add(:system, priority: 1000, content: "Hello")

      assert [piece] = w.pieces
      assert piece.role == :system
      assert piece.priority == 1000
      assert piece.content == "Hello"
    end

    test "auto-increments sequence" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add(:system, priority: 1000, content: "First")
        |> Winnow.add(:user, priority: 500, content: "Second")
        |> Winnow.add(:assistant, priority: 300, content: "Third")

      sequences = Enum.map(w.pieces, & &1.sequence)
      assert sequences == [0, 1, 2]
    end

    test "explicit sequence override" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add(:system, priority: 1000, content: "A", sequence: 10)
        |> Winnow.add(:user, priority: 500, content: "B")

      assert [a, b] = w.pieces
      assert a.sequence == 10
      # next auto sequence is 11
      assert b.sequence == 11
    end

    test "passes through optional fields" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add(:user,
          priority: 500,
          content: "X",
          token_count: 42,
          fallbacks: ["short"],
          section: :memory,
          cacheable: true,
          overflow: :truncate_end
        )

      [piece] = w.pieces
      assert piece.token_count == 42
      assert piece.fallbacks == ["short"]
      assert piece.section == :memory
      assert piece.cacheable == true
      assert piece.overflow == :truncate_end
    end

    test "raises on missing priority" do
      assert_raise KeyError, fn ->
        Winnow.new(budget: 4000) |> Winnow.add(:user, content: "X")
      end
    end

    test "raises on missing content" do
      assert_raise KeyError, fn ->
        Winnow.new(budget: 4000) |> Winnow.add(:user, priority: 500)
      end
    end
  end

  describe "add_each/3" do
    test "adds one piece per item with fixed priority" do
      items = ["alpha", "beta", "gamma"]

      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_each(:user,
          items: items,
          priority: 500,
          formatter: &Function.identity/1
        )

      assert length(w.pieces) == 3

      contents = Enum.map(w.pieces, & &1.content)
      assert contents == ["alpha", "beta", "gamma"]

      priorities = Enum.map(w.pieces, & &1.priority)
      assert priorities == [500, 500, 500]
    end

    test "uses priority_fn for per-item priority" do
      items = ["old", "medium", "new"]

      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_each(:user,
          items: items,
          priority_fn: fn _item, index -> index * 100 end,
          formatter: &Function.identity/1
        )

      priorities = Enum.map(w.pieces, & &1.priority)
      assert priorities == [0, 100, 200]
    end

    test "sequences auto-increment per item" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add(:system, priority: 1000, content: "system")
        |> Winnow.add_each(:user,
          items: ["a", "b"],
          priority: 500,
          formatter: &Function.identity/1
        )

      sequences = Enum.map(w.pieces, & &1.sequence)
      assert sequences == [0, 1, 2]
    end

    test "empty list is a no-op" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_each(:user,
          items: [],
          priority: 500,
          formatter: &Function.identity/1
        )

      assert w.pieces == []
      assert w.next_sequence == 0
    end
  end

  describe "add_tools/3" do
    test "adds tool definitions as system pieces" do
      tools = [
        %{name: "get_weather", description: "Get weather for a location"},
        %{name: "search", description: "Search the web"}
      ]

      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_tools(tools, priority: 750)

      assert length(w.pieces) == 2

      assert Enum.all?(w.pieces, &(&1.role == :system))
      assert Enum.all?(w.pieces, &(&1.type == :tool_def))

      [first, second] = w.pieces
      assert first.content == "get_weather: Get weather for a location"
      assert second.content == "search: Search the web"
    end

    test "supports string-keyed tool maps" do
      tools = [%{"name" => "foo", "description" => "does foo"}]

      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_tools(tools, priority: 500)

      [piece] = w.pieces
      assert piece.content == "foo: does foo"
    end

    test "stores original tool map in metadata" do
      tool = %{name: "search", description: "Search the web", parameters: %{}}

      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_tools([tool], priority: 750)

      [piece] = w.pieces
      assert piece.metadata == tool
    end
  end

  describe "reserve/3" do
    test "creates empty-content piece with fixed token_count" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.reserve(:response, tokens: 500)

      [piece] = w.pieces
      assert piece.content == ""
      assert piece.token_count == 500
      assert piece.priority == :infinity
    end

    test "stores name on the piece" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.reserve(:response, tokens: 500)

      [piece] = w.pieces
      assert piece.name == :response
    end
  end

  describe "pipe chain" do
    test "fluent composition works" do
      w =
        Winnow.new(budget: 10_000)
        |> Winnow.add(:system, priority: 1000, content: "You are an analyst.")
        |> Winnow.add(:user, priority: 900, content: "Current data: ...")
        |> Winnow.add_each(:user,
          items: ["mem1", "mem2"],
          priority: 500,
          formatter: &"Memory: #{&1}"
        )
        |> Winnow.add_tools(
          [%{name: "search", description: "Search"}],
          priority: 750
        )
        |> Winnow.reserve(:response, tokens: 1000)

      assert length(w.pieces) == 6
      sequences = Enum.map(w.pieces, & &1.sequence)
      assert sequences == [0, 1, 2, 3, 4, 5]
    end
  end

  describe "add_tools/3 edge cases" do
    test "empty tools list is a no-op" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_tools([], priority: 500)

      assert w.pieces == []
      assert w.next_sequence == 0
    end
  end

  describe "add_each/3 edge cases" do
    test "single item adds one piece correctly" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_each(:user,
          items: ["only"],
          priority: 500,
          formatter: &Function.identity/1
        )

      assert length(w.pieces) == 1
      assert hd(w.pieces).content == "only"
      assert hd(w.pieces).priority == 500
    end
  end

  describe "reserve/3 edge cases" do
    test "reserved piece not in rendered messages" do
      result =
        Winnow.new(budget: 100)
        |> Winnow.reserve(:response, tokens: 10)
        |> Winnow.add(:system, priority: 1000, content: "Hello", token_count: 5)
        |> Winnow.render()

      # Reserve piece is included but has empty content → excluded from messages
      assert length(result.messages) == 1
      assert hd(result.messages).content == "Hello"
      # But it's in included
      reserve_piece = Enum.find(result.included, &(&1.name == :response))
      assert reserve_piece != nil
      assert reserve_piece.content == ""
    end
  end

  describe "merge/2" do
    test "combines pieces from both structs" do
      left =
        Winnow.new(budget: 1000)
        |> Winnow.add(:system, priority: 1000, content: "Left")

      right =
        Winnow.new(budget: 500)
        |> Winnow.add(:user, priority: 500, content: "Right")

      merged = Winnow.merge(left, right)

      assert length(merged.pieces) == 2
      contents = Enum.map(merged.pieces, & &1.content)
      assert contents == ["Left", "Right"]
    end

    test "right struct sequences are offset" do
      left =
        Winnow.new(budget: 1000)
        |> Winnow.add(:system, priority: 1000, content: "A")
        |> Winnow.add(:user, priority: 500, content: "B")

      right =
        Winnow.new(budget: 500)
        |> Winnow.add(:user, priority: 300, content: "C")
        |> Winnow.add(:user, priority: 200, content: "D")

      merged = Winnow.merge(left, right)

      sequences = Enum.map(merged.pieces, & &1.sequence)
      # Left: 0, 1. Right offset by 2: 2, 3.
      assert sequences == [0, 1, 2, 3]
    end

    test "budget and tokenizer from left struct" do
      left = Winnow.new(budget: 1000, tokenizer: Winnow.Tokenizer.Approximate)
      right = Winnow.new(budget: 500)

      merged = Winnow.merge(left, right)

      assert merged.budget == 1000
      assert merged.tokenizer == Winnow.Tokenizer.Approximate
    end

    test "sections merged" do
      left =
        Winnow.new(budget: 1000)
        |> Winnow.section(:memory, max_tokens: 200)

      right =
        Winnow.new(budget: 500)
        |> Winnow.section(:tools, max_tokens: 100)

      merged = Winnow.merge(left, right)

      assert Map.has_key?(merged.sections, :memory)
      assert Map.has_key?(merged.sections, :tools)
    end

    test "merge where both sides define same section — right overwrites left" do
      left =
        Winnow.new(budget: 1000)
        |> Winnow.section(:memory, max_tokens: 200)

      right =
        Winnow.new(budget: 500)
        |> Winnow.section(:memory, max_tokens: 500)

      merged = Winnow.merge(left, right)

      assert merged.sections.memory.max_tokens == 500
    end

    test "merge with empty right is no-op" do
      left =
        Winnow.new(budget: 1000)
        |> Winnow.add(:system, priority: 1000, content: "A")

      right = Winnow.new(budget: 500)

      merged = Winnow.merge(left, right)

      assert length(merged.pieces) == 1
      assert hd(merged.pieces).content == "A"
    end

    test "end-to-end merge + render" do
      memory =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 500, content: "Memory item", token_count: 10)

      task =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 900, content: "Current task", token_count: 10)

      result =
        Winnow.new(budget: 25)
        |> Winnow.add(:system, priority: 1000, content: "System", token_count: 10)
        |> Winnow.merge(memory)
        |> Winnow.merge(task)
        |> Winnow.render()

      assert result.total_tokens <= 25
      # System + task fit (20), memory dropped at budget 25 if all 3 = 30 > 25
      contents = Enum.map(result.messages, & &1.content)
      assert "System" in contents
      assert "Current task" in contents
    end
  end

  describe "ContentPiece validation" do
    test "rejects invalid overflow value" do
      assert {:error, _} =
               Winnow.ContentPiece.new(
                 role: :user,
                 content: "X",
                 priority: 500,
                 sequence: 0,
                 overflow: :nonsense
               )
    end

    test "rejects invalid type value" do
      assert {:error, _} =
               Winnow.ContentPiece.new(
                 role: :user,
                 content: "X",
                 priority: 500,
                 sequence: 0,
                 type: :nonsense
               )
    end

    test "rejects non-integer, non-infinity priority" do
      assert {:error, _} =
               Winnow.ContentPiece.new(
                 role: :user,
                 content: "X",
                 priority: "high",
                 sequence: 0
               )
    end

    test "rejects float priority" do
      assert {:error, _} =
               Winnow.ContentPiece.new(
                 role: :user,
                 content: "X",
                 priority: 5.0,
                 sequence: 0
               )
    end

    test "accepts :infinity priority" do
      assert {:ok, piece} =
               Winnow.ContentPiece.new(
                 role: :user,
                 content: "X",
                 priority: :infinity,
                 sequence: 0
               )

      assert piece.priority == :infinity
    end

    test "rejects non-binary content" do
      assert {:error, _} =
               Winnow.ContentPiece.new(
                 role: :user,
                 content: 123,
                 priority: 500,
                 sequence: 0
               )
    end

    test "rejects list content" do
      assert {:error, _} =
               Winnow.ContentPiece.new(
                 role: :user,
                 content: ["hello"],
                 priority: 500,
                 sequence: 0
               )
    end
  end
end
