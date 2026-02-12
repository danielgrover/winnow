defmodule Winnow.Tokenizer.TiktokenTest do
  use ExUnit.Case, async: true

  alias Winnow.Tokenizer.Tiktoken

  describe "count_tokens/1" do
    test "known string count" do
      # "Hello world" is 2 tokens in most GPT encodings
      count = Tiktoken.count_tokens("Hello world")
      assert is_integer(count)
      assert count > 0
    end

    test "empty string returns 0" do
      assert Tiktoken.count_tokens("") == 0
    end

    test "matches Tiktoken.count_tokens/2 for gpt-4o" do
      text = "The quick brown fox jumps over the lazy dog"
      assert Tiktoken.count_tokens(text) == Tiktoken.count_tokens(text, "gpt-4o")
    end
  end

  describe "count_tokens/2" do
    test "works with gpt-4 model" do
      count = Tiktoken.count_tokens("Hello world", "gpt-4")
      assert is_integer(count)
      assert count > 0
    end
  end

  describe "message_overhead/0" do
    test "returns 3" do
      assert Tiktoken.message_overhead() == 3
    end
  end

  describe "end-to-end with pipeline" do
    test "renders with tiktoken tokenizer" do
      result =
        Winnow.new(budget: 100, tokenizer: Tiktoken)
        |> Winnow.add(:system, priority: 1000, content: "You are a helpful assistant.")
        |> Winnow.add(:user, priority: 500, content: "Hello!")
        |> Winnow.render()

      assert result.total_tokens > 0
      assert result.total_tokens <= 100
      assert length(result.messages) == 2
    end
  end
end
