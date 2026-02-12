defmodule Winnow.ContentPiece do
  @moduledoc """
  A single piece of prompt content with priority and metadata.

  Every piece has a `role`, `content`, `priority` (higher = more important),
  and `sequence` (determines output ordering). The renderer uses priority to
  decide what fits within the token budget, then orders included pieces by
  sequence.

  ## Required Fields

  - `role` — `:system`, `:user`, or `:assistant`
  - `content` — the text content (string)
  - `priority` — integer, higher means more important
  - `sequence` — integer, determines output order

  ## Optional Fields

  - `token_count` — pre-computed token count (skips tokenizer call)
  - `fallbacks` — ordered list of fallback content strings
  - `section` — atom naming a sub-budget section
  - `cacheable` — hint for cache-friendly ordering (default `false`)
  - `type` — `:text`, `:image`, `:tool_def`, or `:file` (default `:text`).
    Only `:tool_def` has library-level behavior (populates `RenderResult.tools`);
    the others are semantic markers for caller use.
  - `condition` — zero-arity function; piece excluded if it returns `false`
  - `overflow` — `:error`, `:truncate_end`, or `:truncate_middle` (default `:error`)
  - `name` — optional identifier (e.g. for reservations)
  - `metadata` — optional arbitrary data (e.g. original tool map)
  """

  @type t :: %__MODULE__{
          role: :system | :user | :assistant,
          content: String.t(),
          priority: integer() | :infinity,
          sequence: integer(),
          token_count: non_neg_integer() | nil,
          fallbacks: [String.t()],
          section: atom() | nil,
          cacheable: boolean(),
          type: :text | :image | :tool_def | :file,
          condition: (-> boolean()) | nil,
          overflow: :error | :truncate_end | :truncate_middle,
          name: atom() | nil,
          metadata: term()
        }

  @enforce_keys [:role, :content, :priority, :sequence]
  defstruct [
    :role,
    :content,
    :priority,
    :sequence,
    :token_count,
    :section,
    :condition,
    :name,
    :metadata,
    fallbacks: [],
    cacheable: false,
    type: :text,
    overflow: :error
  ]

  @valid_roles [:system, :user, :assistant]
  @valid_overflows [:error, :truncate_end, :truncate_middle]
  @valid_types [:text, :image, :tool_def, :file]

  @doc """
  Creates a new ContentPiece from a keyword list or map.

  Returns `{:ok, piece}` or `{:error, reason}`.

  ## Examples

      iex> Winnow.ContentPiece.new(role: :system, content: "Hello", priority: 1000, sequence: 0)
      {:ok, %Winnow.ContentPiece{role: :system, content: "Hello", priority: 1000, sequence: 0}}
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_list(attrs) do
    attrs |> Map.new() |> new()
  end

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs),
         :ok <- validate_role(attrs),
         :ok <- validate_priority(attrs),
         :ok <- validate_content(attrs),
         :ok <- validate_overflow(attrs),
         :ok <- validate_type(attrs) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @doc """
  Creates a new ContentPiece, raising on invalid input.

  ## Examples

      iex> Winnow.ContentPiece.new!(role: :user, content: "Hi", priority: 500, sequence: 1)
      %Winnow.ContentPiece{role: :user, content: "Hi", priority: 500, sequence: 1}
  """
  @spec new!(keyword() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, piece} -> piece
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp validate_required(attrs) do
    missing =
      [:role, :content, :priority, :sequence]
      |> Enum.reject(&Map.has_key?(attrs, &1))

    case missing do
      [] -> :ok
      fields -> {:error, "missing required fields: #{inspect(fields)}"}
    end
  end

  defp validate_role(%{role: role}) when role in @valid_roles, do: :ok
  defp validate_role(%{role: role}), do: {:error, "invalid role: #{inspect(role)}"}

  defp validate_priority(%{priority: :infinity}), do: :ok
  defp validate_priority(%{priority: p}) when is_integer(p), do: :ok

  defp validate_priority(%{priority: p}),
    do: {:error, "invalid priority: #{inspect(p)}, must be integer or :infinity"}

  defp validate_content(%{content: c}) when is_binary(c), do: :ok

  defp validate_content(%{content: c}),
    do: {:error, "invalid content: expected string, got #{inspect(c)}"}

  defp validate_overflow(%{overflow: overflow}) when overflow in @valid_overflows, do: :ok

  defp validate_overflow(%{overflow: overflow}),
    do: {:error, "invalid overflow: #{inspect(overflow)}"}

  defp validate_overflow(_attrs), do: :ok

  defp validate_type(%{type: type}) when type in @valid_types, do: :ok
  defp validate_type(%{type: type}), do: {:error, "invalid type: #{inspect(type)}"}
  defp validate_type(_attrs), do: :ok
end
