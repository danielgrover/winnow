defmodule Winnow.Section do
  @moduledoc """
  A named section with a token budget cap.

  Sections allow sub-budget control: a section caps how much its pieces can
  use, but never guarantees them space. Its pieces are admitted alongside
  everything else, priority level by priority level, counting against both
  `max_tokens` and the overall budget. If a section's pieces at some level
  don't fit, the section closes — those pieces and its lower-priority ones
  are dropped — while the rest of the prompt carries on.

  Pieces tagged with a section name that was never defined are treated as
  ordinary unsectioned pieces.
  """

  @type t :: %__MODULE__{
          name: atom(),
          max_tokens: non_neg_integer()
        }

  @enforce_keys [:name, :max_tokens]
  defstruct [:name, :max_tokens]
end
