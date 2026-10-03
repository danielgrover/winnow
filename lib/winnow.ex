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

  # Options add/3 accepts (ContentPiece fields minus the role argument).
  @piece_options [
    :priority,
    :content,
    :sequence,
    :token_count,
    :fallbacks,
    :section,
    :cacheable,
    :type,
    :condition,
    :overflow,
    :name,
    :metadata
  ]

  @type t :: %__MODULE__{
          budget: non_neg_integer(),
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
    opts = validate_opts!(opts, [:budget, :tokenizer], [:budget])
    budget = Keyword.fetch!(opts, :budget)
    tokenizer = Keyword.get(opts, :tokenizer, Winnow.Tokenizer.Approximate)

    validate_non_neg_integer!(:budget, budget)
    validate_tokenizer!(tokenizer)

    %__MODULE__{budget: budget, tokenizer: tokenizer}
  end

  @doc """
  Adds a content piece to the prompt.

  ## Options

  - `priority` (required) — integer, higher = more important
  - `content` (required) — text content string
  - `sequence` — explicit sequence number (auto-incremented by default)
  - `token_count` — pre-computed token count (skips tokenizer)
  - `fallbacks` — list of fallback content strings (`""` means omit)
  - `section` — atom naming a sub-budget section
  - `cacheable` — boolean hint for cache-friendly ordering
  - `type` — `:text`, `:image`, `:tool_def`, or `:file`. `:tool_def` pieces
    can't truncate or have non-empty fallbacks, since the full tool definition
    (`metadata`) is sent regardless of content
  - `condition` — zero-arity function; piece excluded at render time if it returns
    a falsy value (`false` or `nil`)
  - `overflow` — `:error`, `:truncate_end`, or `:truncate_middle`
  - `name` — optional atom identifier for the piece
  - `metadata` — arbitrary term carried through to `RenderResult.included`/`dropped`
    (e.g. `{:story, 41}`), useful for knowing which source items made the budget
  """
  @spec add(t(), atom(), keyword()) :: t()
  def add(%__MODULE__{} = winnow, role, opts) do
    {piece, winnow} = build_piece(winnow, role, opts)
    # Append is O(n) per call, O(n²) over many calls. Acceptable for typical
    # prompt piece counts (tens to low hundreds); add_each/3 and add_tools/3
    # append their whole batch at once.
    %{winnow | pieces: winnow.pieces ++ [piece]}
  end

  # Validates opts and builds the piece, advancing next_sequence, without
  # appending it.
  defp build_piece(winnow, role, opts) do
    opts = validate_opts!(opts, @piece_options, [:priority, :content])
    {sequence, winnow} = next_sequence(winnow, opts)

    piece =
      opts
      |> Keyword.put(:role, role)
      |> Keyword.put(:sequence, sequence)
      |> ContentPiece.new!()

    {piece, winnow}
  end

  # Builds one piece per opts list and appends them in a single step.
  defp add_batch(winnow, role, opts_list) do
    {pieces, winnow} =
      Enum.reduce(opts_list, {[], winnow}, fn opts, {pieces, acc} ->
        {piece, acc} = build_piece(acc, role, opts)
        {[piece | pieces], acc}
      end)

    %{winnow | pieces: winnow.pieces ++ Enum.reverse(pieces)}
  end

  @doc """
  Adds multiple content pieces from a list of items.

  Each item is formatted via `formatter` and gets its own `ContentPiece`.
  Priority can be a fixed value or a function `(item, index) -> integer`.

  ## Options

  - `items` (required) — list of items to add
  - `formatter` (required) — `(item -> String.t())` function
  - `priority` or `priority_fn` (one required) — fixed integer or `(item, index) -> integer`
  - `metadata_fn` — `(item -> term())` or `(item, index -> term())`; sets each piece's `metadata`
  - All other options from `add/3` are supported and applied to each piece
  """
  @spec add_each(t(), atom(), keyword()) :: t()
  def add_each(%__MODULE__{} = winnow, role, opts) do
    # :content comes from the formatter and :sequence must differ per item,
    # so neither can be set for the whole batch.
    allowed = [
      :items,
      :formatter,
      :priority_fn,
      :metadata_fn | @piece_options -- [:content, :sequence]
    ]

    opts = validate_opts!(opts, allowed, [:items, :formatter])
    items = Keyword.fetch!(opts, :items)
    formatter = Keyword.fetch!(opts, :formatter)

    unless is_list(items) do
      raise ArgumentError, "invalid items: #{inspect(items)}, must be a list"
    end

    priority_fn = priority_function(opts)
    metadata_fn = Keyword.get(opts, :metadata_fn)

    unless is_function(formatter, 1) do
      raise ArgumentError,
            "invalid formatter: #{inspect(formatter)}, must be a function of arity 1"
    end

    if metadata_fn && Keyword.has_key?(opts, :metadata) do
      raise ArgumentError, "provide either :metadata or :metadata_fn, not both"
    end

    unless is_nil(metadata_fn) or is_function(metadata_fn, 1) or is_function(metadata_fn, 2) do
      raise ArgumentError,
            "invalid metadata_fn: #{inspect(metadata_fn)}, must be a function of arity 1 or 2"
    end

    base_opts = Keyword.drop(opts, [:items, :formatter, :priority_fn, :metadata_fn])

    {opts_list, _count} =
      Enum.map_reduce(items, 0, fn item, index ->
        piece_opts =
          base_opts
          |> Keyword.put(:content, formatter.(item))
          |> Keyword.put(:priority, priority_fn.(item, index))
          |> put_metadata(metadata_fn, item, index)

        {piece_opts, index + 1}
      end)

    add_batch(winnow, role, opts_list)
  end

  defp put_metadata(opts, nil, _item, _index), do: opts

  defp put_metadata(opts, fun, item, _index) when is_function(fun, 1),
    do: Keyword.put(opts, :metadata, fun.(item))

  defp put_metadata(opts, fun, item, index) when is_function(fun, 2),
    do: Keyword.put(opts, :metadata, fun.(item, index))

  @doc """
  Adds tool definitions as content pieces with token costs.

  Each tool becomes a `:system` piece of type `:tool_def` whose `metadata`
  is the tool map. Included tools are returned in `RenderResult.tools` (not
  in `messages`). By default a tool's cost is estimated from its full
  definition (`inspect/1` of the map, including any parameter schema); pass
  `token_count` when you know the real cost.

  ## Options

  - `priority` (required) — integer priority for the tool definitions
  - `token_count` — token cost per tool (applies to every tool in this call)
  - `section`, `cacheable`, `condition`, `name` — as in `add/3`
  - `fallbacks` — only `[""]` (omit), since a tool is sent whole or not at all
  """
  @spec add_tools(t(), [map()], keyword()) :: t()
  def add_tools(%__MODULE__{} = winnow, tools, opts) do
    allowed = [:priority, :token_count, :section, :cacheable, :condition, :name, :fallbacks]
    opts = validate_opts!(opts, allowed, [:priority])

    unless is_list(tools) do
      raise ArgumentError, "invalid tools: #{inspect(tools)}, must be a list of maps"
    end

    opts_list =
      Enum.map(tools, fn
        tool when is_map(tool) ->
          Keyword.merge(opts, content: tool_content(tool), type: :tool_def, metadata: tool)

        tool ->
          raise ArgumentError, "invalid tool: #{inspect(tool)}, must be a map"
      end)

    add_batch(winnow, :system, opts_list)
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
  def reserve(%__MODULE__{} = winnow, name, opts) do
    opts = validate_opts!(opts, [:tokens], [:tokens])
    tokens = Keyword.fetch!(opts, :tokens)
    validate_non_neg_integer!(:tokens, tokens)

    add(winnow, :system,
      priority: :infinity,
      content: "",
      token_count: tokens,
      name: name
    )
  end

  @doc """
  Defines a named section with a token budget cap.

  Pieces added with `section: name` count against both this cap and the
  overall budget. See `Winnow.Section`.

  ## Options

  - `max_tokens` (required) — maximum tokens for this section. This caps
    `:infinity`-priority pieces in the section too; if they exceed it,
    `Winnow.OversizedContentError` is raised with `section` set.
  """
  @spec section(t(), atom(), keyword()) :: t()
  def section(%__MODULE__{} = winnow, name, opts) do
    opts = validate_opts!(opts, [:max_tokens], [:max_tokens])
    max_tokens = Keyword.fetch!(opts, :max_tokens)
    validate_non_neg_integer!(:max_tokens, max_tokens)

    unless is_atom(name) and not is_nil(name) do
      raise ArgumentError, "invalid section name: #{inspect(name)}, must be a non-nil atom"
    end

    section = %Winnow.Section{name: name, max_tokens: max_tokens}
    %{winnow | sections: Map.put(winnow.sections, name, section)}
  end

  @doc """
  Combines two independently-built Winnow structs.

  Budget and tokenizer come from the left (base) struct. The right
  struct's pieces get their sequence numbers offset to come after
  the base's pieces (preserving their relative order). Sections are
  merged; when both define the same name, the right one wins.

  ## Example

      memory = Winnow.new(budget: 1000)
               |> Winnow.add(:user, priority: 500, content: "Memory item")

      task = Winnow.new(budget: 1000)
             |> Winnow.add(:user, priority: 900, content: "Current task")

      full = Winnow.merge(memory, task)
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = left, %__MODULE__{} = right) do
    # Shift so the right side's lowest sequence (which may be explicit or
    # negative) lands just after everything on the left.
    right_min = right.pieces |> Enum.map(& &1.sequence) |> Enum.min(fn -> 0 end) |> min(0)
    offset = left.next_sequence - right_min

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

      explicit when is_integer(explicit) ->
        next = max(winnow.next_sequence, explicit + 1)
        {explicit, %{winnow | next_sequence: next}}

      invalid ->
        raise ArgumentError, "invalid sequence: #{inspect(invalid)}, must be an integer"
    end
  end

  # Options must be a keyword list with only known keys and all required
  # keys present; anything else is an ArgumentError naming the problem.
  defp validate_opts!(opts, allowed, required) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "expected a keyword list of options, got: #{inspect(opts)}"
    end

    keys = Keyword.keys(opts)

    case keys |> Enum.reject(&(&1 in allowed)) |> Enum.uniq() do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown option(s) #{inspect(unknown)}"
    end

    case Enum.uniq(keys -- Enum.uniq(keys)) do
      [] -> :ok
      duplicated -> raise ArgumentError, "duplicate option(s) #{inspect(duplicated)}"
    end

    case required -- Keyword.keys(opts) do
      [] -> opts
      missing -> raise ArgumentError, "missing required option(s) #{inspect(missing)}"
    end
  end

  defp validate_non_neg_integer!(_key, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_neg_integer!(key, value) do
    raise ArgumentError, "invalid #{key}: #{inspect(value)}, must be a non-negative integer"
  end

  defp validate_tokenizer!(tokenizer) do
    if is_atom(tokenizer) and Code.ensure_loaded?(tokenizer) and
         function_exported?(tokenizer, :count_tokens, 1) and
         function_exported?(tokenizer, :message_overhead, 0) do
      :ok
    else
      raise ArgumentError,
            "invalid tokenizer: #{inspect(tokenizer)}, must be a module implementing Winnow.Tokenizer"
    end
  end

  defp priority_function(opts) do
    case {Keyword.fetch(opts, :priority_fn), Keyword.fetch(opts, :priority)} do
      {{:ok, _}, {:ok, _}} ->
        raise ArgumentError, "provide either :priority or :priority_fn, not both"

      {{:ok, fun}, :error} when is_function(fun, 2) ->
        fun

      {{:ok, fun}, :error} ->
        raise ArgumentError, "invalid priority_fn: #{inspect(fun)}, must be a function of arity 2"

      {:error, {:ok, priority}} ->
        fn _item, _index -> priority end

      {:error, :error} ->
        raise ArgumentError, "must provide either :priority or :priority_fn"
    end
  end

  # Cost basis for a tool: its whole definition, schema included.
  defp tool_content(tool), do: inspect(tool, limit: :infinity, printable_limit: :infinity)
end
