defmodule Winnow.OversizedContentError do
  @moduledoc """
  Raised when a single content piece exceeds the remaining token budget
  and its `overflow` option is set to `:error` (the default).
  """

  defexception [:message, :piece, :remaining_budget]

  @impl true
  def exception(opts) do
    piece = Keyword.fetch!(opts, :piece)
    remaining = Keyword.fetch!(opts, :remaining_budget)

    msg =
      "Content piece (priority: #{inspect(piece.priority)}, tokens: #{piece.token_count}) " <>
        "exceeds remaining budget of #{remaining} tokens. " <>
        "Set overflow: :truncate_end or :truncate_middle to auto-truncate."

    %__MODULE__{message: msg, piece: piece, remaining_budget: remaining}
  end
end
