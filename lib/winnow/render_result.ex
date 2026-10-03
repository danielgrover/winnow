defmodule Winnow.RenderResult do
  @moduledoc """
  Output of `Winnow.render/1`.

  Contains the rendered messages, token accounting, and metadata about
  what was included, dropped, and which fallbacks were used.

  ## Fields

  - `messages` — ordered list of `%{role: atom, content: String.t()}` maps.
    Excludes reservations (empty content) and tool definitions.
  - `tools` — metadata (the tool map) of each included `:tool_def` piece
  - `total_tokens` — tokens consumed by included pieces, including reservations
    and tool definitions (so it can exceed what `messages` alone cost)
  - `budget` — the original token budget
  - `threshold` — the lowest admitted priority level. Levels are admitted
    from highest to lowest while their unsectioned pieces (those without a
    `""` fallback) fit. Pieces can still be dropped at or above it: omittable
    ones skipped for lack of room, and those in a section that closed.
    When even the highest finite level isn't admitted, it is one above that
    level; when there are no finite-priority pieces (only `:infinity`, or
    nothing), it is `0`.
  - `included` — `ContentPiece` structs that made the cut, as rendered (content
    may be a fallback or truncated; `token_count` is the actual cost)
  - `dropped` — `ContentPiece` structs that didn't fit, in their original form
  - `fallbacks_used` — `{original_piece, fallback_index}` for each included
    piece rendered from a fallback
  - `cache_breakpoint` — index into `messages` of the last message derived from
    a piece with `cacheable: true`, or `nil` if no cacheable pieces are included.
    Use this to place Anthropic's `cache_control` marker.
  - `condition_excluded` — `ContentPiece` structs excluded because their
    `condition` returned a falsy value (`false` or `nil`). These are neither in
    `included` nor `dropped`; they were removed before the priority/budget pass.

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
