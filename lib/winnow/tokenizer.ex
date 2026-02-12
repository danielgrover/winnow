defmodule Winnow.Tokenizer do
  @moduledoc """
  Behaviour for counting tokens in text strings.

  Implement this behaviour to provide model-specific token counting.
  The library ships with `Winnow.Tokenizer.Approximate` (default) and
  `Winnow.Tokenizer.Tiktoken` (optional, wraps the `tiktoken` package).

  ## Example

      defmodule MyTokenizer do
        @behaviour Winnow.Tokenizer

        @impl true
        def count_tokens(text), do: div(String.length(text), 3)

        @impl true
        def message_overhead, do: 5
      end
  """

  @type token_count :: non_neg_integer()

  @doc "Count tokens in a text string."
  @callback count_tokens(text :: String.t()) :: token_count()

  @doc "Per-message overhead tokens (role markers, structural tokens)."
  @callback message_overhead() :: token_count()
end
