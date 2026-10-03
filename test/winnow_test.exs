defmodule WinnowTest do
  use ExUnit.Case, async: true

  defmodule TwoByteTokenizer do
    @moduledoc false
    @behaviour Winnow.Tokenizer

    @impl true
    def count_tokens(text), do: div(byte_size(text), 2)

    @impl true
    def message_overhead, do: 1
  end

  describe "new/1" do
    test "creates with budget and default tokenizer" do
      w = Winnow.new(budget: 4000)
      assert w.budget == 4000
      assert w.tokenizer == Winnow.Tokenizer.Approximate
      assert w.pieces == []
      assert w.next_sequence == 0
    end

    test "accepts custom tokenizer and uses it to count" do
      result =
        Winnow.new(budget: 4000, tokenizer: TwoByteTokenizer)
        |> Winnow.add(:user, priority: 1, content: "12345678")
        |> Winnow.render()

      # div(8, 2) + 1 overhead (Approximate would give div(8, 4) + 4 = 6)
      assert result.total_tokens == 5
    end

    test "raises without budget" do
      assert_raise ArgumentError, ~r/missing required option\(s\) \[:budget\]/, fn ->
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
      assert_raise ArgumentError, ~r/missing required option\(s\) \[:priority\]/, fn ->
        Winnow.new(budget: 4000) |> Winnow.add(:user, content: "X")
      end
    end

    test "raises on missing content" do
      assert_raise ArgumentError, ~r/missing required option\(s\) \[:content\]/, fn ->
        Winnow.new(budget: 4000) |> Winnow.add(:user, priority: 500)
      end
    end
  end

  describe "add_each/3" do
    test "metadata_fn sets per-item metadata that survives render" do
      items = [%{id: 1, text: "first"}, %{id: 2, text: "second"}]

      result =
        Winnow.new(budget: 4000)
        |> Winnow.add_each(:user,
          items: items,
          priority: 500,
          formatter: & &1.text,
          metadata_fn: &{:story, &1.id}
        )
        |> Winnow.render()

      assert Enum.map(result.included, & &1.metadata) == [{:story, 1}, {:story, 2}]
    end

    test "metadata_fn metadata is preserved on dropped pieces" do
      result =
        Winnow.new(budget: 10)
        |> Winnow.add_each(:user,
          items: [%{id: 1, text: "keep"}, %{id: 2, text: "drop"}],
          priority_fn: fn _item, index -> 100 - index end,
          formatter: & &1.text,
          token_count: 10,
          metadata_fn: &{:story, &1.id}
        )
        |> Winnow.render()

      assert Enum.map(result.included, & &1.metadata) == [{:story, 1}]
      assert Enum.map(result.dropped, & &1.metadata) == [{:story, 2}]
    end

    test "metadata_fn with wrong arity raises ArgumentError" do
      assert_raise ArgumentError, ~r/invalid metadata_fn/, fn ->
        Winnow.new(budget: 100)
        |> Winnow.add_each(:user,
          items: [1],
          priority: 1,
          formatter: &to_string/1,
          metadata_fn: fn a, b, c -> {a, b, c} end
        )
      end
    end

    test "metadata_fn with arity 2 receives the index" do
      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_each(:user,
          items: ["a", "b"],
          priority: 500,
          formatter: &Function.identity/1,
          metadata_fn: fn item, index -> {item, index} end
        )

      assert Enum.map(w.pieces, & &1.metadata) == [{"a", 0}, {"b", 1}]
    end

    test "adds one piece per item with fixed priority" do
      items = ["alpha", "beta", "gamma"]

      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_each(:user,
          items: items,
          priority: 500,
          formatter: &Function.identity/1
        )

      assert [_, _, _] = w.pieces

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

      assert [_, _] = w.pieces

      assert Enum.all?(w.pieces, &(&1.role == :system))
      assert Enum.all?(w.pieces, &(&1.type == :tool_def))

      # Cost basis is the whole definition
      assert Enum.map(w.pieces, & &1.content) == Enum.map(tools, &inspect/1)
    end

    test "supports string-keyed tool maps" do
      tools = [%{"name" => "foo", "description" => "does foo"}]

      w =
        Winnow.new(budget: 4000)
        |> Winnow.add_tools(tools, priority: 500)

      [piece] = w.pieces
      assert piece.content == inspect(hd(tools))
      assert piece.metadata == hd(tools)
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

      assert [_, _, _, _, _, _] = w.pieces
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

      assert [_] = w.pieces
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
      assert [_] = result.messages
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

      assert [_, _] = merged.pieces
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
      right = Winnow.new(budget: 500, tokenizer: TwoByteTokenizer)

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

      assert %{memory: %{max_tokens: 200}, tools: %{max_tokens: 100}} = merged.sections
      assert map_size(merged.sections) == 2
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

      assert Winnow.merge(left, right) == left
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

      # System (1000) + task (900) = 20 fit; adding memory (500) would be 30 > 25
      assert Enum.map(result.messages, & &1.content) == ["System", "Current task"]
      assert [%{content: "Memory item"}] = result.dropped
      assert result.total_tokens == 20
    end
  end

  describe "argument validation" do
    test "new/1 rejects negative or non-integer budget" do
      assert_raise ArgumentError, ~r/invalid budget/, fn -> Winnow.new(budget: -1) end
      assert_raise ArgumentError, ~r/invalid budget/, fn -> Winnow.new(budget: 100.0) end
    end

    test "new/1 rejects a module that doesn't implement Winnow.Tokenizer" do
      assert_raise ArgumentError, ~r/invalid tokenizer/, fn ->
        Winnow.new(budget: 100, tokenizer: String)
      end
    end

    test "reserve/3 rejects negative tokens" do
      assert_raise ArgumentError, ~r/invalid tokens/, fn ->
        Winnow.new(budget: 100) |> Winnow.reserve(:response, tokens: -5)
      end
    end

    test "section/3 rejects non-integer max_tokens" do
      assert_raise ArgumentError, ~r/invalid max_tokens/, fn ->
        Winnow.new(budget: 100) |> Winnow.section(:memory, max_tokens: 30.5)
      end
    end

    test "add/3 rejects non-integer sequence" do
      assert_raise ArgumentError, ~r/invalid sequence/, fn ->
        Winnow.new(budget: 100) |> Winnow.add(:user, priority: 1, content: "x", sequence: "a")
      end
    end

    test "add/3 rejects non-string fallbacks" do
      assert_raise ArgumentError, ~r/invalid fallbacks/, fn ->
        Winnow.new(budget: 100) |> Winnow.add(:user, priority: 1, content: "x", fallbacks: [1])
      end
    end
  end

  describe "merge/2 sequence handling" do
    test "right pieces with negative or explicit sequences still follow the left" do
      left =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 1, content: "L0")
        |> Winnow.add(:user, priority: 1, content: "L1")
        |> Winnow.add(:user, priority: 1, content: "L2")

      right =
        Winnow.new(budget: 100)
        |> Winnow.add(:user, priority: 1, content: "R-first", sequence: -10)
        |> Winnow.add(:user, priority: 1, content: "R1")

      merged = Winnow.merge(left, right)
      messages = merged |> Winnow.render() |> Map.get(:messages) |> Enum.map(& &1.content)

      assert messages == ["L0", "L1", "L2", "R-first", "R1"]
      sequences = Enum.map(merged.pieces, & &1.sequence)
      assert sequences == Enum.uniq(sequences)

      # Later adds still go after everything
      after_add = Winnow.add(merged, :user, priority: 1, content: "next")
      assert List.last(after_add.pieces).sequence > Enum.max(sequences)
    end
  end

  describe "section/3 name validation" do
    test "rejects nil and non-atom names" do
      # apply/3 keeps the type checker from flagging these deliberately bad calls
      for name <- [nil, "memory"] do
        assert_raise ArgumentError, ~r/invalid section name/, fn ->
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          apply(Winnow, :section, [Winnow.new(budget: 100), name, [max_tokens: 10]])
        end
      end
    end
  end

  describe "add_tools/3 validation" do
    test "rejects truncation for tool definitions" do
      assert_raise ArgumentError, ~r/unknown option\(s\) \[:overflow\]/, fn ->
        Winnow.new(budget: 100)
        |> Winnow.add_tools([%{name: "search", description: "Search"}],
          priority: 1,
          overflow: :truncate_end
        )
      end
    end
  end

  describe "add_tools/3 owns its tool fields" do
    @tool %{name: "search", description: "Search the web", parameters: %{q: "string"}}

    test "tools are returned in tools, not duplicated into messages" do
      result =
        Winnow.new(budget: 1000)
        |> Winnow.add(:system, priority: 1000, content: "You are helpful.", cacheable: true)
        |> Winnow.add_tools([@tool], priority: 750)
        |> Winnow.render()

      assert result.tools == [@tool]
      assert Enum.map(result.messages, & &1.content) == ["You are helpful."]
      assert result.cache_breakpoint == 0
    end

    test "default cost covers the parameter schema" do
      w = Winnow.new(budget: 1000) |> Winnow.add_tools([@tool], priority: 750)
      assert hd(w.pieces).content =~ "parameters"
    end

    test "rejects options that would override the tool's own fields" do
      for opt <- [metadata: :mine, type: :text, content: "X", overflow: :truncate_end] do
        assert_raise ArgumentError, ~r/unknown option/, fn ->
          Winnow.new(budget: 1000) |> Winnow.add_tools([@tool], [{:priority, 1}, opt])
        end
      end
    end

    test "rejects non-map tools" do
      assert_raise ArgumentError, ~r/invalid tool/, fn ->
        Winnow.new(budget: 1000) |> Winnow.add_tools(["x"], priority: 1)
      end
    end
  end

  describe "option validation" do
    test "unknown options raise ArgumentError naming them" do
      w = Winnow.new(budget: 100)

      assert_raise ArgumentError, ~r/unknown option\(s\) \[:fallback\]/, fn ->
        Winnow.add(w, :user, priority: 1, content: "x", fallback: ["typo"])
      end

      assert_raise ArgumentError, ~r/unknown option\(s\) \[:budgt\]/, fn ->
        Winnow.new(budgt: 100, budget: 100)
      end

      assert_raise ArgumentError, ~r/unknown option\(s\) \[:section\]/, fn ->
        Winnow.reserve(w, :response, tokens: 5, section: :s)
      end
    end

    test "duplicated options raise naming them" do
      assert_raise ArgumentError, ~r/duplicate option\(s\) \[:priority\]/, fn ->
        Winnow.add(Winnow.new(budget: 10), :user, priority: 1, content: "x", priority: 2)
      end
    end

    test "add_each items and add_tools tools must be lists" do
      w = Winnow.new(budget: 10)

      assert_raise ArgumentError, ~r/invalid items: 5/, fn ->
        Winnow.add_each(w, :user, items: 5, priority: 1, formatter: &to_string/1)
      end

      assert_raise ArgumentError, ~r/invalid tools: %\{name: "a"\}/, fn ->
        # apply/3 keeps the type checker from flagging this deliberately bad call
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Winnow, :add_tools, [w, %{name: "a"}, [priority: 1]])
      end
    end

    test "add_each builds large batches in linear time" do
      {micros, w} =
        :timer.tc(fn ->
          Winnow.add_each(
            Winnow.new(budget: 10),
            :user,
            items: Enum.to_list(1..20_000),
            priority: 1,
            formatter: &to_string/1
          )
        end)

      assert Enum.map(w.pieces, & &1.sequence) == Enum.to_list(0..19_999)
      assert micros < 500_000
    end

    test "maps instead of keyword lists raise ArgumentError" do
      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        # apply/3 keeps the type checker from flagging this deliberately bad call
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Winnow, :new, [%{budget: 10}])
      end
    end

    test "add_each rejects :metadata together with :metadata_fn" do
      assert_raise ArgumentError, ~r/:metadata or :metadata_fn, not both/, fn ->
        Winnow.new(budget: 100)
        |> Winnow.add_each(:user,
          items: [1],
          priority: 1,
          formatter: &to_string/1,
          metadata: :shared,
          metadata_fn: &{:item, &1}
        )
      end
    end

    test "a :tool_def piece added via add/3 needs metadata (or it would vanish)" do
      assert_raise ArgumentError, ~r/missing metadata for :tool_def/, fn ->
        Winnow.new(budget: 100) |> Winnow.add(:system, priority: 1, content: "t", type: :tool_def)
      end

      result =
        Winnow.new(budget: 100)
        |> Winnow.add(:system, priority: 1, content: "t", type: :tool_def, metadata: %{name: "t"})
        |> Winnow.render()

      assert result.tools == [%{name: "t"}]
      assert result.messages == []
    end

    test "add_each rejects conflicting or per-batch-meaningless options" do
      w = Winnow.new(budget: 100)
      base = [items: [1, 2], formatter: &to_string/1]

      assert_raise ArgumentError, ~r/not both/, fn ->
        Winnow.add_each(w, :user, base ++ [priority: 1, priority_fn: fn _, _ -> 1 end])
      end

      assert_raise ArgumentError, ~r/unknown option\(s\) \[:sequence\]/, fn ->
        Winnow.add_each(w, :user, base ++ [priority: 1, sequence: 5])
      end

      assert_raise ArgumentError, ~r/invalid priority_fn/, fn ->
        Winnow.add_each(w, :user, base ++ [priority_fn: fn _ -> 1 end])
      end

      assert_raise ArgumentError, ~r/invalid formatter/, fn ->
        Winnow.add_each(w, :user, items: [1], formatter: "nope", priority: 1)
      end
    end
  end
end
