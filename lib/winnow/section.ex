defmodule Winnow.Section do
  @moduledoc """
  A named section with a token budget cap.

  Sections allow sub-budget control — pieces tagged with a section name
  first compete within that section's budget. The survivors (with any
  fallbacks or truncation already applied) then compete individually, by
  their own priorities, in the main render pass. A section therefore caps
  how much its pieces can use; it never guarantees them space.

  Pieces tagged with a section name that was never defined are treated as
  ordinary main-pass pieces.
  """

  @type t :: %__MODULE__{
          name: atom(),
          max_tokens: non_neg_integer()
        }

  @enforce_keys [:name, :max_tokens]
  defstruct [:name, :max_tokens]
end
