defmodule Winnow.OversizedContentError do
  @moduledoc """
  Raised when a content piece cannot fit and its `overflow` option is
  `:error` (the default).

  Pieces above the priority threshold always fit in at least their cheapest
  form, so in practice this only happens when `:infinity`-priority pieces
  (including `Winnow.reserve/3` reservations) together exceed the budget —
  or, for pieces in a section, that section's `max_tokens` (reported in
  `section`).
  """

  defexception [:message, :piece, :remaining_budget, :section]

  @impl true
  def exception(opts) do
    piece = Keyword.fetch!(opts, :piece)
    remaining = Keyword.fetch!(opts, :remaining_budget)
    section = Keyword.get(opts, :section)
    scope = if section, do: " in section #{inspect(section)}", else: ""

    name = if piece.name, do: "name: #{inspect(piece.name)}, ", else: ""

    msg =
      "Content piece (#{name}priority: #{inspect(piece.priority)}, tokens: #{piece.token_count}) " <>
        "exceeds the #{remaining} tokens available to it#{scope} after setting aside " <>
        "the other :infinity pieces. " <> hint(piece)

    %__MODULE__{message: msg, piece: piece, remaining_budget: remaining, section: section}
  end

  # Empty pieces (e.g. reservations) have no content to truncate; only the
  # budget or the piece's token_count can change.
  defp hint(%{content: ""}), do: "Increase the budget or lower the piece's token_count."

  defp hint(%{overflow: :error}),
    do: "Set overflow: :truncate_end or :truncate_middle to auto-truncate."

  defp hint(_piece), do: "Even its smallest truncation doesn't fit; increase the budget."
end
