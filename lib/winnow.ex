defmodule Winnow do
  @moduledoc """
  Priority-based prompt composition with token budgeting.

  Winnow sits between an agent's context (memory, tools, domain knowledge)
  and the LLM call. Given more content than fits in a context window,
  it keeps what matters most based on priorities.
  """
end
