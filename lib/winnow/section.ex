defmodule Winnow.Section do
  @moduledoc """
  A named section with a token budget cap.

  Sections allow sub-budget control — pieces tagged with a section name
  compete only within that section's budget before being included as a
  fixed-cost block in the main render pass.
  """

  @type t :: %__MODULE__{
          name: atom(),
          max_tokens: pos_integer()
        }

  @enforce_keys [:name, :max_tokens]
  defstruct [:name, :max_tokens]
end
