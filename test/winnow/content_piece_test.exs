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

    test "accepts keyword list" do
      assert {:ok, piece} =
               ContentPiece.new(role: :user, content: "Hi", priority: 500, sequence: 1)

      assert piece.role == :user
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
          type: :tool_def,
          overflow: :truncate_end
        })

      assert {:ok, piece} = ContentPiece.new(attrs)
      assert piece.token_count == 42
      assert piece.fallbacks == ["short version"]
      assert piece.section == :memory
      assert piece.cacheable == true
      assert piece.type == :tool_def
      assert piece.overflow == :truncate_end
    end

    test "accepts condition function" do
      attrs = Map.put(@valid_attrs, :condition, fn -> true end)
      assert {:ok, piece} = ContentPiece.new(attrs)
      assert is_function(piece.condition, 0)
    end

    test "error on missing role" do
      assert {:error, msg} = ContentPiece.new(Map.delete(@valid_attrs, :role))
      assert msg =~ "role"
    end

    test "error on missing content" do
      assert {:error, msg} = ContentPiece.new(Map.delete(@valid_attrs, :content))
      assert msg =~ "content"
    end

    test "error on missing priority" do
      assert {:error, msg} = ContentPiece.new(Map.delete(@valid_attrs, :priority))
      assert msg =~ "priority"
    end

    test "error on missing sequence" do
      assert {:error, msg} = ContentPiece.new(Map.delete(@valid_attrs, :sequence))
      assert msg =~ "sequence"
    end

    test "error on missing multiple fields" do
      assert {:error, msg} = ContentPiece.new(%{})
      assert msg =~ "role"
      assert msg =~ "content"
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
          name: "response"
        ] do
      test "rejects #{field}: #{Macro.to_string(bad)}" do
        bad = unquote(bad)
        expected = "invalid #{unquote(field)}"

        assert {:error, msg} = ContentPiece.new(Map.put(@valid_attrs, unquote(field), bad))
        assert msg =~ expected
      end
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

      assert {:ok, _piece} = ContentPiece.new(attrs)
    end
  end

  describe "new!/1" do
    test "returns piece on valid input" do
      piece = ContentPiece.new!(role: :user, content: "Hi", priority: 500, sequence: 1)
      assert piece.role == :user
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
