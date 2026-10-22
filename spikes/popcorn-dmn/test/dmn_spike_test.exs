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
    assert Highlight.html("< ", {1, 1}) =~ ~s|<span class="op err">&lt;</span>|
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
      assert Types.validate(m, nil, "number") == []
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
      assert length(Types.delete(t, [0, 0])) == 5 and length(Types.get(Types.delete(t, [0, 0]), [0]).components) == 3
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
      assert Layout.run(m2).nodes |> map_size() == 9
      assert Layout.run(%Model{}) == %Model{}
    end
  end

  describe "decision tables" do
    defp table_model(policy, rules) do
      m = Model.sample()
      expr = %{kind: :table, hit_policy: policy, inputs: [%{expr: "Front End Ratio"}], rules: rules}
      put_in(m.nodes["risk"].expr, expr)
    end

    defp risk(m), do: Eval.run(m)["risk"]
    defp rule(entry, out), do: %{entries: [entry], out: out}

    test "the sample table picks the first matching rule" do
      r = risk(Model.sample())
      assert r.value == "Medium"
      assert r.table.matched == [false, true, true]
      assert r.errors == []
    end

    test "UNIQUE needs exactly one match" do
      m = table_model("UNIQUE", [rule("> 10", ~s|"a"|), rule("< 30", ~s|"b"|)])
      r = risk(m)
      assert r.value == nil and r.table.message =~ "2 rules match"
      assert risk(table_model("UNIQUE", [rule("> 10", ~s|"a"|), rule("> 1000", ~s|"b"|)])).value == "a"
      assert risk(table_model("UNIQUE", [rule("> 1000", ~s|"a"|)])).table.message == "no rule matches"
    end

    test "ANY, COLLECT and RULE ORDER" do
      same = [rule("> 10", ~s|"x"|), rule("< 30", ~s|"x"|)]
      assert risk(table_model("ANY", same)).value == "x"
      assert risk(table_model("ANY", [rule("> 10", ~s|"x"|), rule("< 30", ~s|"y"|)])).table.message =~ "disagree"
      assert risk(table_model("COLLECT", same)).value == ["x", "x"]
      assert risk(table_model("RULE ORDER", [rule("> 10", "1"), rule("< 30", "2")])).value |> length() == 2
    end

    test "entries are unary tests: ranges, lists, negation, wildcard" do
      for {entry, expected} <- [{"[20..25]", true}, {"10, 25", false}, {"not(25)", true}, {"-", true}, {"", true}, {"> Back End Ratio - 20", true}, {"< Back End Ratio", true}] do
        r = risk(table_model("FIRST", [rule(entry, ~s|"hit"|)]))
        assert (r.value == "hit") == expected, "entry #{inspect(entry)}"
      end
    end

    test "syntax errors are reported per cell" do
      r = risk(table_model("FIRST", [rule("[1..", ~s|"a"|), rule("-", "1 +")]))
      assert %{"e-0-0" => {:error, _}, "o-1" => {:error, _}} = r.table.errors
    end

    test "adding and removing rules and inputs keeps entries aligned" do
      m = Model.sample()
      m = Model.add_input(m, "risk") |> Model.add_rule("risk")
      t = m.nodes["risk"].expr
      assert length(t.inputs) == 3 and Enum.all?(t.rules, &(length(&1.entries) == 3)) and length(t.rules) == 4
      m = Model.del_input(m, "risk", 0) |> Model.del_rule("risk", 3)
      t = m.nodes["risk"].expr
      assert length(t.inputs) == 2 and Enum.all?(t.rules, &(length(&1.entries) == 2)) and length(t.rules) == 3
      assert Model.set_table_text(m, "risk", ["e", 0, 1], "> 5").nodes["risk"].expr.rules |> hd() |> Map.get(:entries) |> Enum.at(1) == "> 5"
      assert Model.set_expr_kind(m, "risk", :context).nodes["risk"].expr == %{rows: [], result: ""}
    end
  end

  describe "DMN XML" do
    alias DmnSpike.Dmn

    test "export then import reproduces the model exactly" do
      m = Model.sample()
      xml = Dmn.to_xml(m, "Loan")
      assert xml =~ ~s|<?xml version="1.0" encoding="UTF-8"?>|
      assert {:ok, m2, report} = Dmn.from_xml(xml)
      assert m2.nodes == m.nodes
      assert Enum.sort(m2.edges) == Enum.sort(m.edges)
      assert m2.types == m.types
      assert report.dropped == %{} and report.name == "Loan" and report.placed == 0
    end

    test "export is well-formed DMN with the expected structure" do
      xml = Dmn.to_xml(Model.sample())
      assert {:ok, {"definitions", _, _}} = Saxy.SimpleForm.parse_string(xml)
      assert xml =~ ~s|<decision id="risk" name="Risk Category">|
      assert xml =~ ~s|<decisionTable hitPolicy="FIRST">|
      assert xml =~ ~s|<typeConstraint kie:constraintType="range">|
      assert xml =~ ~s|<requiredInput href="#app"/>|
      assert xml =~ ~s|<requiredKnowledge href="#dti"/>|
      assert xml =~ ~s|<dc:Bounds x=|
      assert xml =~ "&lt;= Lender Acceptable PITI"
    end

    test "imports a KIE-style file and reports what it dropped" do
      {:ok, m, r} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      assert r.name == "Loan Pre-Qualification" and r.nodes == 6 and r.types == 3
      assert Map.keys(m.nodes) |> Enum.sort() == ["_app", "_back", "_dti", "_fee", "_loan_d", "_risk"]
      assert %{x: 40, y: 320, w: 160, h: 80} = Map.take(m.nodes["_app"], [:x, :y, :w, :h])
      assert m.nodes["_app"].type_ref == "tApplicant" and m.nodes["_back"].type == :decision
      assert {"_app", "_back", :info} in m.edges and {"_back", "_risk", :info} in m.edges and {"_dti", "_loan_d", :knowledge} in m.edges
      assert length(m.edges) == 6
      assert r.dropped["knowledgeSource"] == 1 and r.dropped["textAnnotation"] == 1 and r.dropped["association"] == 1
      assert r.dropped["authorityRequirement"] == 1
      assert Enum.any?(r.dropped, fn {k, _} -> String.contains?(k, "unsupported expression <invocation>") end)
      assert r.placed == 1 and m.nodes["_fee"].y > m.nodes["_app"].y, "the Fee decision has no DMNShape, so it is placed below the rest"
    end

    test "imported types, tables and contexts evaluate" do
      {:ok, m, _} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      t = Types.find(m, "tApplicant")
      assert [%{name: "Income", constraint: %{kind: :range, text: ">= 0"}}, %{name: "Debt"}] = t.components
      assert Types.find(m, "tCategory").constraint == %{kind: :enumeration, text: ~s|"Low", "Medium", "High"|}
      assert Types.find(m, "tScores").collection
      assert %{kind: :table, hit_policy: "FIRST", rules: [_, _]} = m.nodes["_risk"].expr
      assert %{rows: [%{name: "limit", text: "Lender Acceptable DTI + 5"}]} = m.nodes["_loan_d"].expr
      m = Model.set_text(m, "_app", 0, "{Income: 1000, Debt: 100}")
      r = Eval.run(m)
      assert Decimal.compare(r["_back"].value, 10) == :eq
      assert r["_risk"].value == "Low"
      assert r["_loan_d"].value == "Approve"
    end

    test "rejects non-DMN and malformed input" do
      assert {:error, "not a DMN file" <> _} = Dmn.from_xml("<svg/>")
      assert {:error, "XML parse error" <> _} = Dmn.from_xml("<definitions><decision")
    end

    test "text is escaped both ways" do
      m = Model.set_text(Model.sample(), "dti", 0, ~s|"a<b & c>d"|)
      assert Dmn.to_xml(m) =~ "&quot;" or Dmn.to_xml(m) =~ "a&lt;b &amp; c&gt;d"
      {:ok, m2, _} = Dmn.from_xml(Dmn.to_xml(m))
      assert m2.nodes["dti"].expr.result == ~s|"a<b & c>d"|
    end
  end

  describe "pan and zoom" do
    alias DmnSpike.View

    test "zoom keeps the point under the cursor fixed" do
      {x, y, w, h} = v = {0.0, 0.0, 800.0, 400.0}
      {nx, ny, nw, nh} = View.zoom(v, 0.5, 200.0, 100.0)
      assert {nw, nh} == {400.0, 200.0}
      # the cursor point maps to the same fraction of the view before and after
      assert (200.0 - x) / w == (200.0 - nx) / nw and (100.0 - y) / h == (100.0 - ny) / nh
    end

    test "zoom is clamped and pan moves the origin" do
      assert {_, _, 80.0, _} = View.zoom({0.0, 0.0, 100.0, 50.0}, 0.01, 0.0, 0.0)
      assert {_, _, 200_000.0, _} = View.zoom({0.0, 0.0, 100.0, 50.0}, 1.0e9, 0.0, 0.0)
      assert View.pan({10.0, 20.0, 100.0, 50.0}, -5.0, 7.0) == {5.0, 27.0, 100.0, 50.0}
    end

    test "string round trip" do
      assert View.to_string({1.0, -2.5, 820.0, 370.0}) == "1.0 -2.5 820.0 370.0"
      assert View.parse("0 -30 820 400") == {0.0, -30.0, 820.0, 400.0}
    end
  end
end
