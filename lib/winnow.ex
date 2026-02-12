defmodule Winnow do
  @moduledoc """
  Priority-based prompt composition with token budgeting.

  Winnow sits between an agent's context (memory, tools, domain knowledge)
  and the LLM call. Given more content than fits in a context window,
  it keeps what matters most based on priorities.

  ## Usage

      result =
        Winnow.new(budget: 4000)
        |> Winnow.add(:system, priority: 1000, content: "You are a helpful assistant.")
        |> Winnow.add(:user, priority: 900, content: "Analyze this data...")
        |> Winnow.reserve(:response, tokens: 500)
        |> Winnow.render()

      result.messages      # ordered messages that fit within budget
      result.total_tokens  # tokens consumed
      result.dropped       # what didn't make the cut
  """

  alias Winnow.ContentPiece

  @type t :: %__MODULE__{
          budget: pos_integer(),
          tokenizer: module(),
          pieces: [ContentPiece.t()],
          next_sequence: non_neg_integer(),
          sections: %{atom() => Winnow.Section.t()}
        }

  defstruct [
    :budget,
    :tokenizer,
    pieces: [],
    next_sequence: 0,
    sections: %{}
  ]

  @doc """
  Creates a new Winnow prompt builder.

  ## Options

  - `budget` (required) — maximum token count
  - `tokenizer` — module implementing `Winnow.Tokenizer` (default: `Winnow.Tokenizer.Approximate`)
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    budget = Keyword.fetch!(opts, :budget)
    tokenizer = Keyword.get(opts, :tokenizer, Winnow.Tokenizer.Approximate)

    %__MODULE__{budget: budget, tokenizer: tokenizer}
  end

  @doc """
  Adds a content piece to the prompt.

  ## Options

  - `priority` (required) — integer, higher = more important
  - `content` (required) — text content string
  - `sequence` — explicit sequence number (auto-incremented by default)
  - `token_count` — pre-computed token count (skips tokenizer)
  - `fallbacks` — list of fallback content strings
  - `section` — atom naming a sub-budget section
  - `cacheable` — boolean hint for cache-friendly ordering
  - `type` — `:text`, `:image`, `:tool_def`, or `:file`
  - `condition` — zero-arity function; piece excluded at render time if it returns `false`
  - `overflow` — `:error`, `:truncate_end`, or `:truncate_middle`
  """
  @spec add(t(), atom(), keyword()) :: t()
  def add(%__MODULE__{} = winnow, role, opts) do
    _ = Keyword.fetch!(opts, :priority)
    _ = Keyword.fetch!(opts, :content)

    {sequence, winnow} = next_sequence(winnow, opts)

    piece_attrs =
      opts
      |> Keyword.put(:role, role)
      |> Keyword.put(:sequence, sequence)

    piece = ContentPiece.new!(piece_attrs)
    %{winnow | pieces: winnow.pieces ++ [piece]}
  end

  @doc """
  Adds multiple content pieces from a list of items.

  Each item is formatted via `formatter` and gets its own `ContentPiece`.
  Priority can be a fixed value or a function `(item, index) -> integer`.

  ## Options

  - `items` (required) — list of items to add
  - `formatter` (required) — `(item -> String.t())` function
  - `priority` or `priority_fn` (one required) — fixed integer or `(item, index) -> integer`
  - All other options from `add/3` are supported and applied to each piece
  """
  @spec add_each(t(), atom(), keyword()) :: t()
  def add_each(%__MODULE__{} = winnow, role, opts) do
    items = Keyword.fetch!(opts, :items)
    formatter = Keyword.fetch!(opts, :formatter)
    priority_fn = priority_function(opts)
    base_opts = Keyword.drop(opts, [:items, :formatter, :priority_fn])

    Enum.with_index(items)
    |> Enum.reduce(winnow, fn {item, index}, acc ->
      content = formatter.(item)
      priority = priority_fn.(item, index)

      piece_opts =
        base_opts
        |> Keyword.put(:content, content)
        |> Keyword.put(:priority, priority)

      add(acc, role, piece_opts)
    end)
  end

  @doc """
  Adds tool definitions as content pieces with token costs.

  Tools are added as pieces with role `:system` and type `:tool_def`.
  The content is the tool's description, and token_count should reflect
  the full tool definition cost.

  ## Options

  - `priority` (required) — integer priority for the tool definitions
  - `token_count` — override token count per tool (useful for known costs)
  """
  @spec add_tools(t(), [map()], keyword()) :: t()
  def add_tools(%__MODULE__{} = winnow, tools, opts) do
    priority = Keyword.fetch!(opts, :priority)
    base_opts = Keyword.drop(opts, [:priority])

    Enum.reduce(tools, winnow, fn tool, acc ->
      content = tool_content(tool)

      piece_opts =
        [priority: priority, content: content, type: :tool_def]
        |> Keyword.merge(base_opts)

      add(acc, :system, piece_opts)
    end)
  end

  @doc """
  Reserves tokens without adding visible content.

  Creates an empty-content piece with a fixed `token_count` at the
  maximum priority so it's never dropped. Useful for reserving space
  for model response tokens.

  ## Options

  - `tokens` (required) — number of tokens to reserve
  """
  @spec reserve(t(), atom(), keyword()) :: t()
  def reserve(%__MODULE__{} = winnow, _name, opts) do
    tokens = Keyword.fetch!(opts, :tokens)

    add(winnow, :system,
      priority: :infinity,
      content: "",
      token_count: tokens
    )
  end

  @doc """
  Defines a named section with a token budget cap.

  Pieces added with `section: name` will compete within that section's
  sub-budget before appearing as fixed-cost blocks in the main render.

  ## Options

  - `max_tokens` (required) — maximum tokens for this section
  """
  @spec section(t(), atom(), keyword()) :: t()
  def section(%__MODULE__{} = winnow, name, opts) do
    max_tokens = Keyword.fetch!(opts, :max_tokens)
    section = %Winnow.Section{name: name, max_tokens: max_tokens}
    %{winnow | sections: Map.put(winnow.sections, name, section)}
  end

  @doc """
  Combines two independently-built Winnow structs.

  Budget and tokenizer come from the left (base) struct. The right
  struct's pieces get their sequence numbers offset to come after
  the base's pieces. Sections are merged.

  ## Example

      memory = Winnow.new(budget: 1000)
               |> Winnow.add(:user, priority: 500, content: "Memory item")

      task = Winnow.new(budget: 1000)
             |> Winnow.add(:user, priority: 900, content: "Current task")

      full = Winnow.merge(memory, task)
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    offset = left.next_sequence

    offset_pieces =
      Enum.map(right.pieces, fn piece ->
        %{piece | sequence: piece.sequence + offset}
      end)

    %{
      left
      | pieces: left.pieces ++ offset_pieces,
        next_sequence: offset + right.next_sequence,
        sections: Map.merge(left.sections, right.sections)
    }
  end

  @doc """
  Renders the prompt, computing the priority threshold and producing
  the final message list within the token budget.

  Returns a `Winnow.RenderResult` with messages, token accounting,
  and metadata about included/dropped pieces.
  """
  @spec render(t()) :: Winnow.RenderResult.t()
  def render(%__MODULE__{} = winnow) do
    Winnow.Renderer.render(winnow)
  end

  # Private helpers

  defp next_sequence(winnow, opts) do
    case Keyword.get(opts, :sequence) do
      nil ->
        {winnow.next_sequence, %{winnow | next_sequence: winnow.next_sequence + 1}}

      explicit ->
        next = max(winnow.next_sequence, explicit + 1)
        {explicit, %{winnow | next_sequence: next}}
    end
  end

  defp priority_function(opts) do
    cond do
      Keyword.has_key?(opts, :priority_fn) ->
        Keyword.fetch!(opts, :priority_fn)

      Keyword.has_key?(opts, :priority) ->
        priority = Keyword.fetch!(opts, :priority)
        fn _item, _index -> priority end

      true ->
        raise ArgumentError, "must provide either :priority or :priority_fn"
    end
  end

  defp tool_content(%{name: name, description: desc}), do: "#{name}: #{desc}"
  defp tool_content(%{"name" => name, "description" => desc}), do: "#{name}: #{desc}"
  defp tool_content(tool) when is_map(tool), do: inspect(tool)
end
