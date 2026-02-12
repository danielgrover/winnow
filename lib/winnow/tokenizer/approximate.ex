defmodule Winnow.Tokenizer.Approximate do
  @moduledoc """
  Default tokenizer using byte-size approximation.

  Estimates token count as `div(byte_size(text), 4)`, which is a reasonable
  approximation across most LLM tokenizers (~4 bytes per token on average).

  Uses `byte_size/1` rather than `String.length/1` so multi-byte UTF-8
  characters contribute proportionally more tokens, which is consistent
  with how real tokenizers handle non-ASCII text.

  Message overhead is 4 tokens (a safe default covering both OpenAI and
  Anthropic per-message structural costs).
  """

  @behaviour Winnow.Tokenizer

  @impl true
  @spec count_tokens(String.t()) :: non_neg_integer()
  def count_tokens(text) when is_binary(text) do
    div(byte_size(text), 4)
  end

  @impl true
  @spec message_overhead() :: non_neg_integer()
  def message_overhead, do: 4
end
