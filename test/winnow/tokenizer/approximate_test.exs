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
      # "é" is 2 bytes in UTF-8, div(2, 4) = 0
      assert Approximate.count_tokens("é") == 0

      # "héllo" = 6 bytes (h=1, é=2, l=1, l=1, o=1), div(6, 4) = 1
      assert Approximate.count_tokens("héllo") == 1

      # emoji "🎉" is 4 bytes, div(4, 4) = 1
      assert Approximate.count_tokens("🎉") == 1

      # CJK character "中" is 3 bytes, div(3, 4) = 0
      assert Approximate.count_tokens("中") == 0

      # "中文测试" = 12 bytes (3 * 4), div(12, 4) = 3
      assert Approximate.count_tokens("中文测试") == 3
    end

    property "always returns non-negative" do
      check all(text <- string(:printable)) do
        assert Approximate.count_tokens(text) >= 0
      end
    end

    property "never exceeds byte_size" do
      check all(text <- string(:printable)) do
        assert Approximate.count_tokens(text) <= byte_size(text)
      end
    end
  end

  describe "message_overhead/0" do
    test "returns 4" do
      assert Approximate.message_overhead() == 4
    end
  end
end
