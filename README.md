# Winnow

Priority-based prompt composition with token budgeting for Elixir.

Given more content than fits in a context window, Winnow keeps what matters most. It sits between your agent's context (memory, tools, domain knowledge) and the LLM call, deciding what to include based on priorities.

Zero required dependencies. The core is a data structure and algorithm library.

## Installation

Add `winnow` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:winnow, "~> 0.1.0"},

    # Optional: exact token counting for OpenAI models
    # (enables Winnow.Tokenizer.Tiktoken)
    {:tiktoken, "~> 0.4"}
  ]
end
```

## Quick Start

```elixir
result =
  Winnow.new(budget: 4000)
  |> Winnow.add(:system, priority: 1000, content: "You are a helpful assistant.")
  |> Winnow.add(:user, priority: 900, content: "Analyze the following data...")
  |> Winnow.add(:user, priority: 500, content: long_context)
  |> Winnow.reserve(:response, tokens: 500)
  |> Winnow.render()

result.messages      # ordered messages that fit within budget
result.total_tokens  # tokens consumed
result.dropped       # what didn't fit
result.threshold     # computed priority cutoff
```

## API

### Building a Prompt

**`Winnow.new/1`** — create a prompt builder with a token budget.

```elixir
w = Winnow.new(budget: 128_000)
w = Winnow.new(budget: 128_000, tokenizer: Winnow.Tokenizer.Tiktoken)
```

**`Winnow.add/3`** — add a content piece with a role and priority.

```elixir
w
|> Winnow.add(:system, priority: 1000, content: "You are an analyst.")
|> Winnow.add(:user, priority: 500, content: domain_knowledge)
```

**`Winnow.add_each/3`** — add multiple items from a list.

```elixir
w |> Winnow.add_each(:user,
  items: memory_items,
  priority_fn: fn _item, index -> 400 + index end,
  formatter: fn item -> "Memory: #{item.content}" end,
  metadata_fn: &{:memory, &1.id}   # optional; arity 1 or 2 (item, index)
)
```

`metadata` (or `metadata_fn` here) is carried through to `result.included` and
`result.dropped`, so you can tell which source items made the budget.

**`Winnow.add_tools/3`** — add tool definitions as prioritized pieces.

```elixir
w |> Winnow.add_tools(
  [%{name: "search", description: "Search the web"}],
  priority: 750
)
```

**`Winnow.reserve/3`** — reserve tokens for model response.

```elixir
w |> Winnow.reserve(:response, tokens: 4000)
```

### Rendering

**`Winnow.render/1`** — compute the priority threshold and produce the final message list.

Returns a `Winnow.RenderResult` with:
- `messages` — ordered message maps (`%{role: atom, content: String.t()}`)
- `total_tokens` — tokens consumed
- `budget` — the original budget
- `threshold` — computed priority cutoff
- `included` / `dropped` — which pieces made it and which didn't
- `fallbacks_used` — pieces where a fallback was used
- `tools` — tool definitions (from `add_tools/3`) that made the budget; these are
  not repeated in `messages`

### Fallbacks

Provide alternative content for when the primary doesn't fit:

```elixir
w
|> Winnow.add(:user,
  priority: 500,
  content: full_document,
  fallbacks: [summary, one_liner]
)
```

The renderer tries the primary first, then each fallback in order, then omits. An empty-string fallback (`""`) explicitly means "omit" — the piece is reported in `dropped`.

### Sections (Sub-budgets)

Cap token allocation for named sections:

```elixir
Winnow.new(budget: 128_000)
|> Winnow.section(:memory, max_tokens: 30_000)
|> Winnow.add(:user, priority: 500, content: "...", section: :memory)
```

Pieces within a section compete against each other within the section's budget. Survivors then compete individually, by their own priorities, in the main render — a section caps how much its pieces can use but never guarantees them space.

### Conditions

Include pieces conditionally at render time:

```elixir
w
|> Winnow.add(:user,
  priority: 500,
  content: challenge_context,
  condition: fn -> challenge != nil end
)
```

### Overflow Handling

Control what happens when a piece is too large:

```elixir
w
|> Winnow.add(:user,
  priority: 500,
  content: huge_document,
  overflow: :truncate_end    # or :truncate_middle, default :error
)
```

Pieces above the threshold always fit in at least their cheapest form, so `:error` only raises
(`Winnow.OversizedContentError`) when `:infinity`-priority pieces — including reservations — exceed
the budget on their own, or exceed their section's `max_tokens`.

### Merging

Combine independently-built prompt sections:

```elixir
memory_section = build_memory_section(agent_memory)
task_section = build_task_section(current_task)

Winnow.new(budget: 128_000)
|> Winnow.merge(memory_section)
|> Winnow.merge(task_section)
|> Winnow.render()
```

### Custom Tokenizers

Implement the `Winnow.Tokenizer` behaviour:

```elixir
defmodule MyTokenizer do
  @behaviour Winnow.Tokenizer

  @impl true
  def count_tokens(text), do: # your logic

  @impl true
  def message_overhead, do: 4
end

Winnow.new(budget: 128_000, tokenizer: MyTokenizer)
```

Built-in tokenizers:
- `Winnow.Tokenizer.Approximate` — `div(byte_size(text), 4)`, zero dependencies (default)
- `Winnow.Tokenizer.Tiktoken` — exact counts via tiktoken, requires optional dep

## How It Works

1. Each content piece has a **priority** (what to include) and **sequence** (output order)
2. Priority levels are admitted from highest to lowest while the pieces fit the budget in their cheapest form (smallest fallback, or smallest truncation). The lowest admitted level is the **threshold**; everything below is dropped. A piece with a `""` (omit) fallback that doesn't fit is skipped without blocking lower levels.
3. Every admitted piece is included with real content
4. Pieces are then resolved in priority order: each gets its primary, a fallback, or a truncation — whatever fits after reserving the minimum cost of the pieces still to come. Spare room goes to the most important pieces first.
5. Output is ordered by sequence, not priority

## Best Practices

**Prioritize the edges.** LLMs attend more to the beginning and end of their context window (the "lost in the middle" effect). Place your highest-signal content at low sequence numbers (system prompt, instructions) and high sequence numbers (current task, user query). Background context and memory sit in the middle where it's OK if attention is weaker.

**Use `cacheable: true` for stable content.** System prompts, tool definitions, and other content that rarely changes between calls should be marked `cacheable: true` and placed at the start (low sequence numbers). After rendering, use `result.cache_breakpoint` to place Anthropic's `cache_control: %{type: "ephemeral"}` marker on the corresponding message — everything up to and including that index can be cached across requests.

**Less is more.** Dropping low-priority content isn't just a budget constraint — it often *improves* output quality. Irrelevant context dilutes attention (sometimes called "context rot"). Trust Winnow's priority system: if content is borderline useful, give it a low priority and let the renderer drop it when space is tight.

## Inspirations

Winnow draws from several systems and ideas in the prompt engineering ecosystem:

- **[Priompt](https://github.com/anysphere/priompt)** (Anysphere/Cursor) — the priority-based threshold algorithm, binary search for budget fitting, and fallback mechanism that form Winnow's core render pipeline
- **Anthropic's prompt engineering patterns** — the 4-block prompt structure (Instructions, Context, Task, Output Format) informed how priorities map to prompt sections
- **[vscode-prompt-tsx](https://github.com/microsoft/vscode-prompt-tsx)** (Microsoft) — priority-based pruning in VS Code Copilot validated this approach for production use
- **[LangChain](https://github.com/langchain-ai/langchain)** — memory management categories (buffer/summary/hybrid) informed what Winnow deliberately does *not* handle: content generation and summarization live upstream

Adapted for Elixir's data-driven style — structs and pure functions instead of JSX or class hierarchies.

## License

MIT — see [LICENSE](LICENSE).
