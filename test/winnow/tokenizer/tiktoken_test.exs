defmodule Winnow.Tokenizer.TiktokenTest do
  use ExUnit.Case, async: true

  # Aliased under a distinct name so `Tiktoken` still means the underlying
  # library, which the wrapper is checked against.
  alias Winnow.Tokenizer.Tiktoken, as: TiktokenTokenizer

  # Tokenizes very differently under o200k_base (gpt-4o) and cl100k_base
  # (gpt-4), so it shows which encoding is actually in use.
  @multilingual "Здравствуйте, мир! 你好世界"

  describe "count_tokens/1" do
    test "known string count" do
      assert TiktokenTokenizer.count_tokens("Hello world") == 2
      assert TiktokenTokenizer.count_tokens("The quick brown fox jumps over the lazy dog") == 9
    end

    test "empty string returns 0" do
      assert TiktokenTokenizer.count_tokens("") == 0
    end

    test "defaults to the gpt-4o encoding" do
      {:ok, library_count} = Tiktoken.count_tokens("gpt-4o", @multilingual)

      assert TiktokenTokenizer.count_tokens(@multilingual) == library_count
      assert TiktokenTokenizer.count_tokens(@multilingual) == 7
    end
  end

  describe "count_tokens/2" do
    test "uses the given model's encoding" do
      assert TiktokenTokenizer.count_tokens(@multilingual, "gpt-4o") == 7
      assert TiktokenTokenizer.count_tokens(@multilingual, "gpt-4") == 16
    end

    test "raises on an unsupported model" do
      assert_raise RuntimeError, ~r/unsupported_model/, fn ->
        TiktokenTokenizer.count_tokens("x", "not-a-model")
      end
    end
  end

  describe "message_overhead/0" do
    test "returns 3" do
      assert TiktokenTokenizer.message_overhead() == 3
    end
  end

  describe "end-to-end with pipeline" do
    test "renders with exact tiktoken costs" do
      result =
        Winnow.new(budget: 100, tokenizer: TiktokenTokenizer)
        |> Winnow.add(:system, priority: 1000, content: "You are a helpful assistant.")
        |> Winnow.add(:user, priority: 500, content: "Hello!")
        |> Winnow.render()

      # 6 + 3 overhead, 2 + 3 overhead
      assert Enum.map(result.included, & &1.token_count) == [9, 5]
      assert result.total_tokens == 14
      assert [_, _] = result.messages
    end

    test "drops by priority using real token counts" do
      # 9 + 5 = 14 tokens; a budget of 13 only fits the system prompt.
      result =
        Winnow.new(budget: 13, tokenizer: TiktokenTokenizer)
        |> Winnow.add(:system, priority: 1000, content: "You are a helpful assistant.")
        |> Winnow.add(:user, priority: 500, content: "Hello!")
        |> Winnow.render()

      assert Enum.map(result.messages, & &1.content) == ["You are a helpful assistant."]
      assert [%{content: "Hello!"}] = result.dropped
      assert result.total_tokens == 9
    end
  end
end
