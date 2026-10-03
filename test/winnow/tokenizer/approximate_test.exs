defmodule Winnow.Tokenizer.ApproximateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Winnow.Tokenizer.Approximate

  describe "count_tokens/1" do
    test "empty string returns 0" do
      assert Approximate.count_tokens("") == 0
    end

    test "known ASCII strings" do
      # "hello" = 5 bytes, div(5, 4) = 1
      assert Approximate.count_tokens("hello") == 1

      # "hello world" = 11 bytes, div(11, 4) = 2
      assert Approximate.count_tokens("hello world") == 2

      # 16 bytes exactly = 4 tokens
      assert Approximate.count_tokens("abcdefghijklmnop") == 4
    end

    test "multi-byte UTF-8 uses byte_size not String.length" do
      # Each of these differs between div(byte_size, 4) and
      # div(String.length, 4), so counting characters would fail them.

      # emoji "🎉" is 1 character, 4 bytes: div(4, 4) = 1 (chars would give 0)
      assert Approximate.count_tokens("🎉") == 1

      # "中文测试" is 4 characters, 12 bytes: div(12, 4) = 3 (chars would give 1)
      assert Approximate.count_tokens("中文测试") == 3

      # "éééé" is 4 characters, 8 bytes: div(8, 4) = 2 (chars would give 1)
      assert Approximate.count_tokens("éééé") == 2
    end

    property "is exactly div(byte_size, 4)" do
      check all(text <- one_of([string(:printable), string(:utf8)])) do
        assert Approximate.count_tokens(text) == div(byte_size(text), 4)
      end
    end
  end

  describe "message_overhead/0" do
    test "returns 4" do
      assert Approximate.message_overhead() == 4
    end
  end
end
