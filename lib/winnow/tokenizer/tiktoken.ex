defmodule Winnow.Tokenizer.Tiktoken do
  @moduledoc """
  Tokenizer wrapping the `tiktoken` hex package for exact OpenAI token counts.

  Requires the optional `tiktoken` dependency. Defaults to the `"gpt-4o"` model
  encoding. Message overhead is 3 tokens (per OpenAI's documented per-message cost).

  ## Usage

      # Default (gpt-4o)
      Winnow.new(budget: 128_000, tokenizer: Winnow.Tokenizer.Tiktoken)

      # Custom model — use a configured module
      defmodule MyTiktoken do
        @behaviour Winnow.Tokenizer
        @impl true
        def count_tokens(text), do: Winnow.Tokenizer.Tiktoken.count_tokens(text, "gpt-4")
        @impl true
        def message_overhead, do: 3
      end
  """

  @behaviour Winnow.Tokenizer

  @default_model "gpt-4o"

  @impl true
  @spec count_tokens(String.t()) :: non_neg_integer()
  def count_tokens(text) do
    count_tokens(text, @default_model)
  end

  @doc """
  Count tokens for a specific model.

  Returns the exact token count using tiktoken's encoding for the given model.
  """
  @spec count_tokens(String.t(), String.t()) :: non_neg_integer()
  def count_tokens(text, model) do
    case Tiktoken.count_tokens(model, text) do
      {:ok, count} -> count
      {:error, reason} -> raise "Tiktoken error: #{inspect(reason)}"
    end
  end

  @impl true
  @spec message_overhead() :: non_neg_integer()
  def message_overhead, do: 3
end
