defmodule DmnSpikeTest do
  use ExUnit.Case

  alias DmnSpike.{Autocomplete, Eval, Highlight, Model, Svg}

  test "svg renders every node and edge, with arrow markers" do
    m = Model.sample()
    svg = Svg.scene(m, %{}, nil)
    assert length(String.split(svg, ~s(class="vis"))) - 1 == length(m.edges)
    assert length(String.split(svg, "data-id=")) - 1 == map_size(m.nodes)
    assert svg =~ "marker-end=\"url(#arrow-open)\""
    assert svg =~ "marker-end=\"url(#arrow-fill)\""
  end

  test "edges stop at node borders, not centres" do
    m = Model.sample()
    {x, y} = Svg.border(m.nodes["loan"], Svg.center(m.nodes["back"]))
    n = m.nodes["loan"]
    assert x >= n.x and x <= n.x + n.w and y >= n.y and y <= n.y + n.h
    near = fn a, b -> abs(a - b) < 0.2 end
    assert near.(x, n.x) or near.(x, n.x + n.w) or near.(y, n.y) or near.(y, n.y + n.h)
  end

  test "move updates only the target node" do
    m = Model.move(Model.sample(), "loan", 10.4, 20.6)
    assert %{x: 10, y: 21} = m.nodes["loan"]
    assert m.nodes["back"] == Model.sample().nodes["back"]
  end

  test "evaluates the sample DRD in requirement order" do
    r = Eval.run(Model.sample())
    assert r["loan"].value == "Qualified"
    assert Decimal.compare(r["front"].value, 28) == :lt
    assert Enum.all?(r["front"].cells, &match?({:ok, _, _}, &1))
  end

  test "values format readably" do
    assert DmnSpike.Fmt.value(%{"B" => Decimal.new("2.50"), "A" => "x"}) == ~s|{A: "x", B: 2.5}|
    assert String.length(DmnSpike.Fmt.short(%{"Income" => Decimal.new(9000), "Debt" => Decimal.new(800), "Tax" => 1})) <= 22
  end

  test "editing an input changes dependents" do
    m = Model.set_text(Model.sample(), "app", 0, "{Income: 1000, Tax: 400, Insurance: 120, Debt: 800}")
    assert Eval.run(m)["loan"].value == "Not qualified"
  end

  test "highlight keeps the text and tags tokens" do
    html = Highlight.html(~s|if x > 1 then "a" else sum(2.5) // hi|)
    assert html =~ ~s|<span class="k">if</span>|
    assert html =~ ~s|<span class="s">&quot;a&quot;</span>|
    assert html =~ ~s|<span class="fn">sum</span>|
    assert html =~ ~s|<span class="n">2.5</span>|
    assert html =~ ~s|<span class="c"> // hi</span>|
    strip = fn h -> h |> String.replace(~r/<[^>]+>/, "") |> String.replace("&gt;", ">") |> String.replace("&quot;", "\"") end
    assert strip.(html) == ~s|if x > 1 then "a" else sum(2.5) // hi|
  end

  test "highlight marks the error span" do
    assert Highlight.html("1 +", {3, 3}) =~ "err eof"
    assert Highlight.html(~s|"abc|) =~ ~s|class="err"|
  end

  test "autocomplete suggests scope names and accepts a pick" do
    m = Model.sample()
    text = "if Applicant Da"
    {start, names} = Autocomplete.suggest(m, "back", 0, text, String.length(text))
    assert "Applicant Data" in names
    {new, caret} = Autocomplete.accept(text, String.length(text), start, names, Enum.find_index(names, &(&1 == "Applicant Data")))
    assert new == "if Applicant Data" and caret == String.length(new)
  end

  alias DmnSpike.{Layout, Types}

  describe "data types" do
    test "the sample DRD conforms to its types" do
      r = Eval.run(Model.sample())
      assert Enum.all?(r, fn {_, v} -> v.errors == [] end)
    end

    test "constraints and structure are checked" do
      m = Model.sample()
      d = &Decimal.new/1
      assert Types.validate(m, d.(50), "tRatio") == []
      assert Types.validate(m, d.(150), "tRatio") == ["violates constraint [0..100]"]
      assert Types.validate(m, "maybe", "tVerdict") == [~s|violates constraint "Qualified", "Not qualified"|]
      assert Types.validate(m, d.(7), "tRequested") == ["expected a structure"]
      bad = %{"Amount" => d.(1), "Rate" => d.(25), "Term" => d.(100)}
      assert ["Rate: violates constraint (0..20]", "Term: violates constraint 120, 180, 240, 360"] = Types.validate(m, bad, "tRequested")
      assert Types.validate(m, "x", "number") == ["expected a number"]
      assert Types.validate(m, nil, "tRatio") == []
      assert Types.validate(m, 1, "nope") == ["unknown type nope"]
    end

    test "collections validate every item" do
      m = %{Model.sample() | types: [%{Types.new_type("tList") | ref: "number", collection: true}]}
      assert Types.validate(m, [Decimal.new(1), Decimal.new(2)], "tList") == []
      assert Types.validate(m, [Decimal.new(1), "x"], "tList") == ["expected a number"]
      assert Types.validate(m, Decimal.new(1), "tList") == ["expected a list"]
    end

    test "invalid constraint text is reported" do
      assert %Feel.Error{} = Types.constraint_error(%{kind: :range, text: "[1.."})
      assert Types.constraint_error(%{kind: :range, text: ">= 0"}) == nil
    end

    test "path edits and rename refactor references" do
      m = Model.sample()
      t = Types.update(m.types, [0, 1], &%{&1 | name: "Levy"})
      assert Types.get(t, [0, 1]).name == "Levy"
      assert length(Types.delete(t, [0, 0])) == 4 and length(Types.get(Types.delete(t, [0, 0]), [0]).components) == 3
      m2 = Types.rename_top(m, 2, "tPercent")
      assert m2.nodes["front"].type_ref == "tPercent" and Types.find(m2, "tPercent")
    end
  end

  describe "editing the diagram" do
    test "add_node places a uniquely named node centred on the drop point" do
      {m, id} = Model.add_node(Model.sample(), "decision", 400, 300)
      {m, id2} = Model.add_node(m, "decision", 10, 10)
      assert %{x: 325, y: 270, name: "New decision"} = m.nodes[id]
      assert m.nodes[id2].name == "New decision 2"
    end

    test "connect follows the DMN requirement rules" do
      m = Model.sample()
      assert {:error, "already connected"} = Model.connect(m, "app", "front")
      assert {:error, "a node cannot require itself"} = Model.connect(m, "app", "app")
      assert {:error, "that would create a cycle"} = Model.connect(m, "loan", "front")
      assert {:error, "input cannot be required by input"} = Model.connect(m, "app", "prod")
      {m, id} = Model.add_node(m, "decision", 0, 0)
      assert {:ok, m2} = Model.connect(m, "front", id)
      assert {_, _, :info} = List.last(m2.edges)
      assert {:ok, m3} = Model.connect(m, "dti", id)
      assert {_, _, :knowledge} = List.last(m3.edges)
    end

    test "delete_node drops its edges" do
      m = Model.delete_node(Model.sample(), "front")
      refute Map.has_key?(m.nodes, "front")
      assert Enum.all?(m.edges, fn {a, b, _} -> a != "front" and b != "front" end)
    end
  end

  describe "auto layout" do
    test "layers respect requirements and nodes do not overlap" do
      m = Layout.run(Model.sample())
      for {from, to, _} <- m.edges, do: assert(m.nodes[from].y > m.nodes[to].y)

      boxes = Map.values(m.nodes)

      for a <- boxes, b <- boxes, a.id < b.id do
        overlap? = a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
        refute overlap?, "#{a.name} overlaps #{b.name}"
      end
    end

    test "is stable (idempotent) and handles disconnected and empty models" do
      m = Layout.run(Model.sample())
      assert Layout.run(m) == m
      {m2, _} = Model.add_node(Model.sample(), "input", 0, 0)
      assert Layout.run(m2).nodes |> map_size() == 8
      assert Layout.run(%Model{}) == %Model{}
    end
  end
end
