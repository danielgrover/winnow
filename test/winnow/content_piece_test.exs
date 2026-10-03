defmodule Winnow.ContentPieceTest do
  use ExUnit.Case, async: true

  alias Winnow.ContentPiece

  doctest ContentPiece

  @valid_attrs %{role: :system, content: "Hello", priority: 1000, sequence: 0}

  describe "new/1" do
    test "creates piece with all required fields" do
      assert {:ok, piece} = ContentPiece.new(@valid_attrs)
      assert piece.role == :system
      assert piece.content == "Hello"
      assert piece.priority == 1000
      assert piece.sequence == 0
    end

    test "accepts keyword list, same as a map" do
      assert ContentPiece.new(Enum.to_list(@valid_attrs)) == ContentPiece.new(@valid_attrs)
    end

    test "sets defaults" do
      assert {:ok, piece} = ContentPiece.new(@valid_attrs)
      assert piece.fallbacks == []
      assert piece.cacheable == false
      assert piece.type == :text
      assert piece.condition == nil
      assert piece.overflow == :error
      assert piece.token_count == nil
      assert piece.section == nil
    end

    test "accepts optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          token_count: 42,
          fallbacks: ["short version"],
          section: :memory,
          cacheable: true,
          type: :file,
          overflow: :truncate_end
        })

      assert {:ok, piece} = ContentPiece.new(attrs)
      assert piece.token_count == 42
      assert piece.fallbacks == ["short version"]
      assert piece.section == :memory
      assert piece.cacheable == true
      assert piece.type == :file
      assert piece.overflow == :truncate_end
    end

    test "accepts condition function" do
      condition = fn -> true end
      assert {:ok, piece} = ContentPiece.new(Map.put(@valid_attrs, :condition, condition))
      assert piece.condition == condition
    end

    test "error on missing role" do
      assert ContentPiece.new(Map.delete(@valid_attrs, :role)) ==
               {:error, "missing required fields: [:role]"}
    end

    test "error on missing content" do
      assert ContentPiece.new(Map.delete(@valid_attrs, :content)) ==
               {:error, "missing required fields: [:content]"}
    end

    test "error on missing priority" do
      assert ContentPiece.new(Map.delete(@valid_attrs, :priority)) ==
               {:error, "missing required fields: [:priority]"}
    end

    test "error on missing sequence" do
      assert ContentPiece.new(Map.delete(@valid_attrs, :sequence)) ==
               {:error, "missing required fields: [:sequence]"}
    end

    test "error on missing multiple fields" do
      assert ContentPiece.new(%{}) ==
               {:error, "missing required fields: [:role, :content, :priority, :sequence]"}
    end

    test "error on invalid role" do
      assert {:error, msg} = ContentPiece.new(%{@valid_attrs | role: :invalid})
      assert msg =~ "invalid role"
    end

    test "accepts all valid roles" do
      for role <- [:system, :user, :assistant] do
        assert {:ok, piece} = ContentPiece.new(%{@valid_attrs | role: role})
        assert piece.role == role
      end
    end
  end

  describe "new/1 — optional field validation" do
    for {field, bad} <- [
          token_count: -1,
          token_count: 1.5,
          fallbacks: "not a list",
          fallbacks: ["ok", :not_a_string],
          section: "memory",
          condition: true,
          condition: quote(do: fn _x -> true end),
          cacheable: "yes",
          name: "response",
          sequence: 1.5,
          priority: 1.5,
          priority: "high",
          content: 123,
          content: ["hello"],
          overflow: :wrap,
          type: :video
        ] do
      test "rejects #{field}: #{Macro.to_string(bad)}" do
        bad = unquote(bad)
        expected = "invalid #{unquote(field)}"

        assert {:error, msg} = ContentPiece.new(Map.put(@valid_attrs, unquote(field), bad))
        assert msg =~ expected
      end
    end

    test "rejects content and fallbacks that aren't valid UTF-8" do
      assert {:error, msg} = ContentPiece.new(%{@valid_attrs | content: <<0xFF, 0xFE>>})
      assert msg =~ "UTF-8"

      assert {:error, msg} = ContentPiece.new(Map.put(@valid_attrs, :fallbacks, [<<0x80>>]))
      assert msg =~ "UTF-8"
    end

    test ":tool_def pieces can't truncate or have non-empty fallbacks" do
      tool = Map.merge(@valid_attrs, %{type: :tool_def, metadata: %{name: "t"}})

      assert {:error, msg} = ContentPiece.new(Map.put(tool, :overflow, :truncate_end))
      assert msg =~ "can't be truncated"

      assert {:error, msg} = ContentPiece.new(Map.put(tool, :fallbacks, ["short"]))
      assert msg =~ "only \"\" (omit)"

      assert {:ok, _} = ContentPiece.new(Map.put(tool, :fallbacks, [""]))

      assert {:error, msg} = ContentPiece.new(Map.delete(tool, :metadata))
      assert msg =~ "missing metadata"
    end

    test "unknown fields return an error instead of raising" do
      assert {:error, msg} = ContentPiece.new(Map.put(@valid_attrs, :bogus, 1))
      assert msg =~ "unknown field(s): [:bogus]"
    end

    test "accepts valid optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          token_count: 0,
          fallbacks: ["short"],
          section: :memory,
          condition: fn -> true end,
          cacheable: true,
          name: :intro
        })

      assert {:ok, piece} = ContentPiece.new(attrs)
      assert Map.take(piece, Map.keys(attrs)) == attrs
    end
  end

  describe "new!/1" do
    test "returns piece on valid input" do
      assert ContentPiece.new!(@valid_attrs) == elem(ContentPiece.new(@valid_attrs), 1)
    end

    test "raises ArgumentError on invalid input" do
      assert_raise ArgumentError, ~r/missing required/, fn ->
        ContentPiece.new!(%{})
      end
    end

    test "raises on invalid role" do
      assert_raise ArgumentError, ~r/invalid role/, fn ->
        ContentPiece.new!(role: :bad, content: "x", priority: 1, sequence: 0)
      end
    end
  end
end
