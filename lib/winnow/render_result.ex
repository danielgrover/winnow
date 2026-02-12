defmodule Winnow.RenderResult do
  @moduledoc """
  Output of `Winnow.render/1`.

  Contains the rendered messages, token accounting, and metadata about
  what was included, dropped, and which fallbacks were used.

  ## Fields

  - `messages` — ordered list of `%{role: atom, content: String.t()}` maps
  - `tools` — list of tool definition maps
  - `total_tokens` — tokens consumed by included content
  - `budget` — the original token budget
  - `threshold` — the computed priority threshold
  - `included` — list of `ContentPiece` structs that made the cut
  - `dropped` — list of `ContentPiece` structs that didn't fit
  - `fallbacks_used` — list of `{ContentPiece, fallback_index}` tuples
  - `cache_breakpoint` — index into `messages` of the last message derived from
    a piece with `cacheable: true`, or `nil` if no cacheable pieces are included.
    Use this to place Anthropic's `cache_control` marker.
  - `condition_excluded` — list of `ContentPiece` structs excluded by their
    `condition` function returning `false`. These are neither in `included` nor
    `dropped`; they were removed before the priority/budget pass.

  ## Example

      iex> %Winnow.RenderResult{}
      %Winnow.RenderResult{messages: [], tools: [], total_tokens: 0, budget: 0, threshold: 0, included: [], dropped: [], fallbacks_used: [], cache_breakpoint: nil, condition_excluded: []}
  """

  @type t :: %__MODULE__{
          messages: [map()],
          tools: [map()],
          total_tokens: non_neg_integer(),
          budget: non_neg_integer(),
          threshold: number(),
          included: [Winnow.ContentPiece.t()],
          dropped: [Winnow.ContentPiece.t()],
          fallbacks_used: [{Winnow.ContentPiece.t(), non_neg_integer()}],
          cache_breakpoint: non_neg_integer() | nil,
          condition_excluded: [Winnow.ContentPiece.t()]
        }

  defstruct messages: [],
            tools: [],
            total_tokens: 0,
            budget: 0,
            threshold: 0,
            included: [],
            dropped: [],
            fallbacks_used: [],
            cache_breakpoint: nil,
            condition_excluded: []
end
