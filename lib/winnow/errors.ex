defmodule Winnow.OversizedContentError do
  @moduledoc """
  Raised when a content piece cannot fit and its `overflow` option is
  `:error` (the default).

  Pieces above the priority threshold always fit in at least their cheapest
  form, so in practice this only happens when `:infinity`-priority pieces
  (including `Winnow.reserve/3` reservations) together exceed the budget.
  """

  defexception [:message, :piece, :remaining_budget]

  @impl true
  def exception(opts) do
    piece = Keyword.fetch!(opts, :piece)
    remaining = Keyword.fetch!(opts, :remaining_budget)

    name = if piece.name, do: "name: #{inspect(piece.name)}, ", else: ""

    msg =
      "Content piece (#{name}priority: #{inspect(piece.priority)}, tokens: #{piece.token_count}) " <>
        "exceeds remaining budget of #{remaining} tokens. " <> hint(piece)

    %__MODULE__{message: msg, piece: piece, remaining_budget: remaining}
  end

  # Reservations have no content to truncate; the budget itself is too small.
  defp hint(%{content: ""}), do: "Increase the budget or reduce the reservation."
  defp hint(_piece), do: "Set overflow: :truncate_end or :truncate_middle to auto-truncate."
end
