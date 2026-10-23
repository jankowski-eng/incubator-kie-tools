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

    assert String.length(DmnSpike.Fmt.short(%{"Income" => Decimal.new(9000), "Debt" => Decimal.new(800), "Tax" => 1})) <=
             22
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

    strip = fn h ->
      h |> String.replace(~r/<[^>]+>/, "") |> String.replace("&gt;", ">") |> String.replace("&quot;", "\"")
    end

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

    {new, caret} =
      Autocomplete.accept(text, String.length(text), start, names, Enum.find_index(names, &(&1 == "Applicant Data")))

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

      assert ["Rate: violates constraint (0..20]", "Term: violates constraint 120, 180, 240, 360"] =
               Types.validate(m, bad, "tRequested")

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

    test "add_required creates a node the target requires, without overlapping another" do
      m = Model.sample()
      assert Model.required_kinds(:decision) == ["input", "decision", "bkm"]
      assert Model.required_kinds(:bkm) == ["bkm"]
      assert Model.required_kinds(:input) == []

      {:ok, m, id} = Model.add_required(m, "front", "input")
      assert {id, "front", :info} in m.edges
      n = m.nodes[id]
      assert n.type == :input

      refute Enum.any?(m.nodes, fn {k, o} ->
               k != id and n.x < o.x + o.w and o.x < n.x + n.w and n.y < o.y + o.h and o.y < n.y + n.h
             end)

      # a second one lands somewhere else
      {:ok, m, id2} = Model.add_required(m, "front", "input")
      assert {m.nodes[id2].x, m.nodes[id2].y} != {n.x, n.y}

      {:ok, m, bkm} = Model.add_required(m, "front", "bkm")
      assert {bkm, "front", :knowledge} in m.edges

      assert {:error, _} = Model.add_required(m, "app", "decision")
      assert {:error, _} = Model.add_required(m, "dti", "decision")
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

  describe "auto layout and artifacts" do
    test "annotations and sources follow the element they are linked to, groups and loose ones stay" do
      m = Model.sample()
      {:ok, m, note} = Model.add_required(m, "front", "annotation")
      {:ok, m, src} = Model.add_required(m, "loan", "source")
      {m, loose} = Model.add_node(m, "annotation", 700, 700)
      {m, group} = Model.add_node(m, "group", 300, 300)
      # shake the decision nodes so that layout has to move them
      m = Model.move(m, "front", 5, 5)
      before = m.nodes

      laid = Layout.run(m)
      shift = fn id -> {laid.nodes[id].x - before[id].x, laid.nodes[id].y - before[id].y} end

      assert shift.("front") != {0, 0}, "the layout did move the node"
      assert shift.(note) == shift.("front")
      assert shift.(src) == shift.("loan")
      assert shift.(loose) == {0, 0}
      assert shift.(group) == {0, 0}
    end
  end

  describe "a blank model" do
    alias DmnSpike.{Dmn, Eval, XmlIndex}

    test "evaluates, exports and imports as an empty DMN" do
      m = %Model{}
      assert Eval.run(m) == %{}
      assert DmnSpike.Svg.viewbox(m) == "0 0 820 370"
      x = XmlIndex.build(m, "Untitled")
      assert x.ranges == [] and x.text =~ ~s|name="Untitled"|
      assert {:ok, m2, report} = Dmn.from_xml(x.text)
      assert map_size(m2.nodes) == 0 and m2.edges == [] and m2.types == [] and report.name == "Untitled"
    end

    test "the first node can be a decision table" do
      {m, id} = Model.add_node(%Model{}, "decision", 410, 185)
      m = Model.set_expr_kind(m, id, :table)
      assert Model.kind(m.nodes[id]) == :table
      assert m.nodes[id].x == 335 and m.nodes[id].y == 155
    end
  end

  describe "XML source ranges" do
    alias DmnSpike.{Dmn, XmlIndex, XmlView}

    defp imported(file) do
      {:ok, m, _} = Dmn.from_xml(File.read!(Path.join(__DIR__, "fixtures/" <> file)))
      m
    end

    test "the indexed document is the same text as to_xml" do
      m = Model.sample()
      x = XmlIndex.build(m, "Loan")
      assert x.text == Dmn.to_xml(m, "Loan")
      assert Enum.join(x.lines, "\n") <> "\n" == x.text
    end

    test "each range starts and ends on the element it names" do
      x = XmlIndex.build(Model.sample())

      for {from, to, key} <- x.ranges do
        open = x.lines |> Enum.at(from - 1) |> String.trim()
        close = x.lines |> Enum.at(to - 1) |> String.trim()
        tag = open |> String.trim_leading("<") |> String.split([" ", ">", "/"]) |> hd()
        assert String.starts_with?(open, "<" <> tag), inspect({key, open})

        assert close == "</#{tag}>" or String.ends_with?(close, "/>") or String.contains?(close, "</#{tag}>"),
               inspect({key, close})
      end

      {from, to} = XmlView.range(x, {:node, "front"})
      assert Enum.at(x.lines, from - 1) == ~s|  <decision id="front" name="Front End Ratio">|
      assert Enum.at(x.lines, to - 1) == "  </decision>"
      {from, _} = XmlView.range(x, {:type, [0, 1]})
      assert Enum.at(x.lines, from - 1) == ~s|    <itemComponent id="_t0-1" name="Tax">|
      {from, _} = XmlView.range(x, {:edge, "front", "risk"})
      assert Enum.at(x.lines, from - 1) =~ ~s|<informationRequirement id="_req-front-risk">|
    end

    test "a position resolves to the most specific element, or to nothing" do
      x = XmlIndex.build(Model.sample())
      {from, to} = XmlView.range(x, {:node, "front"})
      assert XmlView.key_at(x, from) == {:node, "front"}
      assert XmlView.key_at(x, div(from + to, 2)) == {:node, "front"}
      {rf, _} = XmlView.range(x, {:edge, "app", "front"})
      assert XmlView.key_at(x, rf + 1) == {:edge, "app", "front"}
      assert XmlView.key_at(x, 1) == nil
      assert XmlView.key_at(x, 2) == nil
    end

    test "ranges follow the model: a rename keeps the key, a new node adds one, a deleted one is gone" do
      m = Model.sample()
      renamed = Model.rename(m, "risk", "Risk Level")
      assert XmlView.range(XmlIndex.build(renamed), {:node, "risk"}) != nil

      assert Enum.at(
               XmlIndex.build(renamed).lines,
               elem(XmlView.range(XmlIndex.build(renamed), {:node, "risk"}), 0) - 1
             ) =~ "Risk Level"

      {added, id} = Model.add_node(m, "decision", 10, 10)
      assert XmlView.range(XmlIndex.build(added), {:node, id}) != nil
      assert XmlView.range(XmlIndex.build(Model.delete_node(added, id)), {:node, id}) == nil
    end

    test "the lines are exactly the text the writer produces, fresh or imported" do
      for model <- [Model.sample(), imported("Sample.dmn"), imported("kie_sample.dmn")] do
        x = XmlIndex.build(model)
        assert x.text == Dmn.to_xml(model)
        {header, root} = Dmn.document(model)
        {body, _spans, _n} = Dmn.render_lines(root)
        assert header <> Enum.join(body, "\n") <> "\n" == x.text
      end
    end

    test "an imported file is indexed by the ids it carries: every node, requirement and type" do
      for file <- ["Sample.dmn", "kie_sample.dmn"] do
        m = imported(file)
        x = XmlIndex.build(m)

        for {id, n} <- m.nodes do
          {from, _} = XmlView.range(x, {:node, id}) || flunk("#{file}: no range for node #{n.name}")
          assert Enum.at(x.lines, from - 1) =~ ~s|id="#{id}"|
        end

        for {from_id, to_id, _} <- Model.edges_all(m) do
          assert XmlView.range(x, {:edge, from_id, to_id}), "#{file}: no range for #{from_id} -> #{to_id}"
        end

        for {t, i} <- Enum.with_index(m.types) do
          {from, _} = XmlView.range(x, {:type, [i]}) || flunk("#{file}: no range for type #{t.name}")
          assert Enum.at(x.lines, from - 1) =~ ~s|name="#{t.name}"|

          for {c, j} <- Enum.with_index(t.components) do
            {from, _} = XmlView.range(x, {:type, [i, j]}) || flunk("#{file}: no range for #{t.name}.#{c.name}")
            assert Enum.at(x.lines, from - 1) =~ ~s|name="#{c.name}"|
          end
        end
      end
    end

    test "clicking inside an imported decision resolves to it" do
      m = imported("Sample.dmn")
      x = XmlIndex.build(m)
      [{id, _} | _] = Enum.filter(m.nodes, fn {_, n} -> n.type == :decision end)
      {from, to} = XmlView.range(x, {:node, id})
      assert XmlView.key_at(x, from) == {:node, id}
      # in the middle it is the decision itself, or a requirement written inside it that points at it
      assert match?(
               k when k == {:node, id} or (elem(k, 0) == :edge and elem(k, 2) == id),
               XmlView.key_at(x, div(from + to, 2))
             )
    end

    test "a text with a line break still counts every line" do
      m = put_in(Model.sample().nodes["loan"].expr.result, "1 +\n 2")
      x = XmlIndex.build(m)
      assert length(x.lines) == length(String.split(String.trim_trailing(x.text, "\n"), "\n"))
      {from, to} = XmlView.range(x, {:node, "loan"})
      assert Enum.at(x.lines, from - 1) =~ "<decision"
      assert Enum.at(x.lines, to - 1) == "  </decision>"
    end

    test "highlighting keeps the exact text of every line" do
      m = put_in(Model.sample().nodes["loan"].expr.result, ~s|if a < b & c > "d" then 1|)

      strip = fn h ->
        h
        |> String.replace(~r/<[^>]+>/, "")
        |> String.replace("&lt;", "<")
        |> String.replace("&gt;", ">")
        |> String.replace("&quot;", "\"")
        |> String.replace("&amp;", "&")
      end

      for l <- XmlIndex.build(m).lines, do: assert(strip.(XmlView.highlight(l)) == l)
    end
  end

  describe "type constraints" do
    alias DmnSpike.Constraint

    test "visual forms are recognised only when they reproduce the text exactly" do
      assert Constraint.parse(">= 0", :range) == {:cmp, ">=", "0"}
      assert Constraint.parse("(0..20]", :range) == {:interval, "(", "0", "20", "]"}
      assert Constraint.parse("120, 180, 240, 360", :enumeration) == {:list, ~w(120 180 240 360)}
      assert Constraint.parse(~s|"Low", "Med, ium"|, :enumeration) == {:list, [~s|"Low"|, ~s|"Med, ium"|]}
      assert Constraint.parse("5", :range) == :advanced
      assert Constraint.parse(~s|> date("2020-01-01")|, :range) == :advanced
      assert Constraint.parse("> 0 and < 100", :expression) == :advanced
      assert Constraint.parse("]0..5[", :range) == :advanced
    end

    test "build writes canonical text that parses back to the same form" do
      for form <- [{:cmp, "<=", "10"}, {:interval, "[", "0", "100", ")"}, {:list, ["1", "2"]}] do
        assert Constraint.parse(Constraint.build(form), Constraint.kind(form)) == form
      end
    end

    test "string values are quoted once" do
      assert Constraint.literal("string", "Low") == ~s|"Low"|
      assert Constraint.literal("string", ~s|"Low"|) == ~s|"Low"|
      assert Constraint.literal("number", " 7 ") == "7"
    end

    test "names, references and usages" do
      m = Model.sample()
      assert DmnSpike.Types.name_error(m.types, [0, 0]) == nil
      dup = %{m | types: DmnSpike.Types.update(m.types, [0, 1], &%{&1 | name: "Income"})}
      assert DmnSpike.Types.name_error(dup.types, [0, 1]) =~ "already used"

      assert DmnSpike.Types.name_error(%{m | types: DmnSpike.Types.update(m.types, [0], &%{&1 | name: " "})}.types, [0]) =~
               "required"

      assert DmnSpike.Types.ref_error(m, %{ref: "tNope"}) =~ "Unknown"

      assert DmnSpike.Types.usages(m, "tRatio").nodes == [
               "Back End Ratio",
               "Front End Ratio",
               "Risk Category (input column 1)",
               "Risk Category (input column 2)"
             ]

      assert DmnSpike.Types.usages(m, "tApplicant").nodes == ["Applicant Data"]
      assert DmnSpike.Types.base(m, %{ref: "tRatio"}) == "number"
      assert DmnSpike.Types.fetch(m.types, [9]) == nil and DmnSpike.Types.fetch(m.types, [0, 9]) == nil
    end
  end

  describe "decision tables" do
    defp table_model(policy, rules) do
      m = Model.sample()

      expr = %{
        kind: :table,
        hit_policy: policy,
        inputs: [%{expr: "Front End Ratio"}],
        outputs: [%{name: ""}],
        rules: rules
      }

      put_in(m.nodes["risk"].expr, expr)
    end

    defp risk(m), do: Eval.run(m)["risk"]
    defp rule(entry, out), do: %{entries: [entry], outs: [out]}

    test "the sample table picks the first matching rule" do
      r = risk(Model.sample())
      assert r.value == "Medium"
      assert r.table.matched == [false, true, true]
      assert r.table.chosen == [1]
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
      for {entry, expected} <- [
            {"[20..25]", true},
            {"10, 25", false},
            {"not(25)", true},
            {"-", true},
            {"", true},
            {"> Back End Ratio - 20", true},
            {"< Back End Ratio", true}
          ] do
        r = risk(table_model("FIRST", [rule(entry, ~s|"hit"|)]))
        assert r.value == "hit" == expected, "entry #{inspect(entry)}"
      end
    end

    test "syntax errors are reported per cell" do
      r = risk(table_model("FIRST", [rule("[1..", ~s|"a"|), rule("-", "1 +")]))
      assert %{"e-0-0" => {:error, _}, "o-1-0" => {:error, _}} = r.table.errors
    end

    test "an edge can arrive at a chosen side of its target" do
      m = Model.sample()
      {:ok, plain} = Model.connect(m, "app", "loan")
      {:ok, m} = Model.connect(m, "app", "loan", :left)
      assert plain.anchors == %{} and m.anchors == %{{"app", "loan"} => :left}

      {x1, y1, x2, y2} = Svg.endpoints(m, "app", "loan")
      loan = m.nodes["loan"]
      assert {x2, y2} == {loan.x * 1.0, loan.y + loan.h / 2}
      assert {x1, y1} == Svg.border(m.nodes["app"], {x2, y2})
      assert Svg.endpoints(plain, "app", "loan") != {x1, y1, x2, y2}

      assert Model.delete_edge(m, length(m.edges) - 1).anchors == %{}
      assert Model.delete_node(m, "loan").anchors == %{}
      assert {:error, _} = Model.connect(m, "app", "loan", :left)
    end

    test "the nearest side is the one whose anchor is closest" do
      n = %{x: 100, y: 100, w: 150, h: 60}
      assert Svg.nearest_side(n, {170, 90}) == :top
      assert Svg.nearest_side(n, {260, 135}) == :right
      assert Svg.nearest_side(n, {170, 200}) == :bottom
      assert Svg.nearest_side(n, {60, 120}) == :left
    end

    test "inserting at a position shifts the rest and keeps the rules aligned" do
      m =
        Model.sample()
        |> Model.insert_rule("risk", 1)
        |> Model.insert_input("risk", 0)
        |> Model.insert_output("risk", 1)

      t = m.nodes["risk"].expr
      assert Enum.map(t.rules, & &1.outs) == [[~s|"Low"|, ""], ["", ""], [~s|"Medium"|, ""], [~s|"High"|, ""]]
      assert Enum.map(t.rules, &hd(&1.entries)) == ["-", "-", "-", "-"]
      assert hd(t.inputs).expr == "" and Enum.at(t.inputs, 1).expr == "Front End Ratio"
      assert Enum.all?(t.rules, &(length(&1.entries) == 3 and length(&1.outs) == 2))
    end

    test "column types are set per column and survive the XML round trip" do
      m =
        Model.sample()
        |> Model.set_col_type("risk", :input, 0, "number")
        |> Model.set_col_type("risk", :input, 1, nil)
        |> Model.set_col_type("risk", :output, 0, "string")

      xml = DmnSpike.Dmn.to_xml(m)
      assert xml =~ ~s|<inputExpression typeRef="number">| and xml =~ ~s|typeRef="string"|
      {:ok, m2, _} = DmnSpike.Dmn.from_xml(xml)
      t = m2.nodes["risk"].expr
      assert hd(t.inputs).type_ref == "number" and Enum.at(t.inputs, 1).type_ref == nil
      assert hd(t.outputs).type_ref == "string"
    end

    test "adding and removing rules and inputs keeps entries aligned" do
      m = Model.sample()
      m = Model.add_input(m, "risk") |> Model.add_rule("risk")
      t = m.nodes["risk"].expr
      assert length(t.inputs) == 3 and Enum.all?(t.rules, &(length(&1.entries) == 3)) and length(t.rules) == 4
      m = Model.del_input(m, "risk", 0) |> Model.del_rule("risk", 3)
      t = m.nodes["risk"].expr
      assert length(t.inputs) == 2 and Enum.all?(t.rules, &(length(&1.entries) == 2)) and length(t.rules) == 3

      assert Model.set_table_text(m, "risk", ["e", 0, 1], "> 5").nodes["risk"].expr.rules
             |> hd()
             |> Map.get(:entries)
             |> Enum.at(1) == "> 5"

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
      # the test values of the inputs are scenarios, not part of the file
      blank = fn nodes ->
        Map.new(nodes, fn {id, n} -> {id, if(n.type == :input, do: put_in(n.expr.result, ""), else: n)} end)
      end

      assert blank.(m2.nodes) == blank.(m.nodes)
      assert Enum.sort(m2.edges) == Enum.sort(m.edges)
      assert Enum.map(m2.types, &Map.delete(&1, :origin)) == m.types
      assert report.dropped == %{} and report.name == "Loan" and report.placed == 0
    end

    test "export is well-formed DMN with the expected structure" do
      xml = Dmn.to_xml(Model.sample())
      assert {:ok, {"definitions", _, _}} = Saxy.SimpleForm.parse_string(xml)
      assert xml =~ ~s|<decision id="risk" name="Risk Category">|
      assert xml =~ ~s|<decisionTable hitPolicy="FIRST">|
      assert xml =~ ~s|<allowedValues kie:constraintType="range">|
      assert xml =~ ~s|<requiredInput href="#app"/>|
      assert xml =~ ~s|<requiredKnowledge href="#dti"/>|
      assert xml =~ ~s|<dc:Bounds x=|
      assert xml =~ "&lt;= Lender Acceptable PITI"
    end

    test "imports a KIE-style file and reports what it dropped" do
      {:ok, m, r} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      assert r.name == "Loan Pre-Qualification" and r.nodes == 6 and r.types == 3

      assert Map.keys(m.nodes) |> Enum.sort() == [
               "_app",
               "_back",
               "_bureau",
               "_dti",
               "_fee",
               "_loan_d",
               "_note",
               "_risk"
             ]

      assert %{x: 40, y: 320, w: 160, h: 80} = Map.take(m.nodes["_app"], [:x, :y, :w, :h])
      assert m.nodes["_app"].type_ref == "tApplicant" and m.nodes["_back"].type == :decision

      assert {"_app", "_back", :info} in m.edges and {"_back", "_risk", :info} in m.edges and
               {"_dti", "_loan_d", :knowledge} in m.edges

      assert length(m.edges) == 6
      assert r.artifacts == %{annotation: 1, source: 1}
      assert m.nodes["_note"].type == :annotation and m.nodes["_note"].name == "Draft rules, review quarterly"
      assert Enum.sort(m.links) == [{"_bureau", "_loan_d", :authority}, {"_note", "_back", :association}]
      assert m.nodes["_bureau"].type == :source and m.nodes["_bureau"].name == "Credit Bureau"
      assert r.kept == %{}
      assert r.dropped == %{}
      assert r.converted == %{"Fee: invocation to a FEEL function call" => 1}
      assert m.nodes["_fee"].expr.result == "feeFunction()"

      assert r.placed == 3 and m.nodes["_fee"].y > m.nodes["_app"].y,
             "the Fee decision and the annotation have no DMNShape, so they are placed below the rest"
    end

    test "imported types, tables and contexts evaluate" do
      {:ok, m, _} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      t = Types.find(m, "tApplicant")
      assert [%{name: "Income", constraint: %{kind: :range, text: ">= 0"}}, %{name: "Debt"}] = t.components
      assert Types.find(m, "tCategory").constraint == %{kind: :enumeration, text: ~s|"Low", "Medium", "High"|}
      assert Types.find(m, "tScores").collection
      assert %{kind: :table, hit_policy: "FIRST", rules: [_, _]} = m.nodes["_risk"].expr
      assert %{rows: [%{name: "limit", text: "Lender Acceptable DTI() + 5"}]} = m.nodes["_loan_d"].expr
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

  describe "business knowledge as functions" do
    test "a BKM with parameters is callable, positionally and by name" do
      m = Model.sample() |> Model.set_params("dti", "x") |> Model.set_text("dti", 0, "x * 2")
      call = fn text -> Model.set_text(m, "loan", 0, text) |> Eval.run() |> Map.fetch!("loan") |> Map.fetch!(:value) end
      assert call.(~s|if Back End Ratio <= Lender Acceptable DTI(x: 18) then "ok" else "no"|) == "ok"
      assert call.(~s|if Back End Ratio <= Lender Acceptable DTI(10) then "ok" else "no"|) == "no"
    end

    test "a BKM body can be a context, and the node's value is the function" do
      m = Model.sample()
      m = put_in(m.nodes["dti"].expr, %{rows: [%{name: "a", text: "x + 1"}], result: "a * 2", params: ["x"]})
      r = Eval.run(m)
      assert DmnSpike.Fmt.value(r["dti"].value) == "ƒ(x)"
      assert r["dti"].errors == []
      m = Model.set_text(m, "loan", 0, ~s|Lender Acceptable DTI(x: 4)|)
      assert Decimal.compare(Eval.run(m)["loan"].value, 10) == :eq
    end

    test "parameter lists are parsed from text" do
      m = Model.set_params(Model.sample(), "dti", " a, b ,, c ")
      assert Model.params(m.nodes["dti"]) == ["a", "b", "c"]
    end
  end

  describe "multiple output columns" do
    test "several outputs give a context keyed by output name" do
      m =
        Model.sample()
        |> Model.add_output("risk")
        |> Model.set_table_text("risk", ["n", 0], "category")
        |> Model.set_table_text("risk", ["n", 1], "why")

      m = m |> Model.set_table_text("risk", ["o", 1, 1], ~s|"medium because < 28"|)
      r = Eval.run(m)["risk"]
      assert r.value == %{"category" => "Medium", "why" => "medium because < 28"}
    end

    test "outputs stay aligned when added and removed, and the last one cannot go" do
      m = Model.sample() |> Model.add_output("risk") |> Model.add_rule("risk")
      t = m.nodes["risk"].expr
      assert length(t.outputs) == 2 and Enum.all?(t.rules, &(length(&1.outs) == 2))
      m = m |> Model.del_output("risk", 0) |> Model.del_output("risk", 0)
      t = m.nodes["risk"].expr
      assert length(t.outputs) == 1 and Enum.all?(t.rules, &(length(&1.outs) == 1))
    end
  end

  describe "the real KIE sample (Sample.dmn from sandbox.kie.org)" do
    alias DmnSpike.Dmn

    setup do
      {:ok, m, r} = Dmn.from_xml(File.read!("test/fixtures/Sample.dmn"))
      id = fn name -> Enum.find_value(m.nodes, fn {i, n} -> if n.name == name, do: i end) end
      %{m: m, r: r, id: id}
    end

    defp with_inputs(m, id, income, fico) do
      m
      |> Model.set_text(
        id.("Applicant Data"),
        0,
        ~s|{Age: 35, Marital Status: "S", Employment Status: "Employed", Existing Customer: false, Monthly: {Income: #{income}, Repayments: 100, Expenses: 2000, Tax: 300, Insurance: 100}}|
      )
      |> Model.set_text(id.("Requested Product"), 0, ~s|{Type: "Standard Loan", Rate: 4.5, Term: 360, Amount: 300000}|)
      |> Model.set_text(id.("Credit Score"), 0, "{FICO: #{fico}}")
    end

    test "imports every element", %{m: m, r: r} do
      assert {r.nodes, r.edges, r.types, r.placed} == {11, 11, 16, 0}
      assert m.nodes |> Map.values() |> Enum.frequencies_by(& &1.type) == %{input: 3, decision: 4, bkm: 4}
      assert r.dropped == %{} and r.kept == %{}, "nothing in the real sample is lost or merely kept"

      assert r.converted == %{
               "Back End Ratio: invocation to a FEEL function call" => 1,
               "Front End Ratio: invocation to a FEEL function call" => 1
             }
    end

    test "business knowledge models are functions with their parameters", %{m: m, id: id} do
      assert Model.params(m.nodes[id.("PITI")]) == ["pmt", "tax", "insurance", "income"]
      assert Model.params(m.nodes[id.("DTI")]) == ["d", "i"]
      assert Model.params(m.nodes[id.("Lender Acceptable PITI")]) == []
    end

    test "evaluates to the right qualification and reason", %{m: m, id: id} do
      out = fn income, fico ->
        r = m |> with_inputs(id, income, fico) |> Eval.run()
        assert Enum.all?(r, fn {_, v} -> v.errors == [] end), "values must conform to the model's data types"
        {r[id.("Credit Score Rating")].value, r[id.("Loan Pre-Qualification")].value}
      end

      assert {"Good", %{"Qualification" => "Qualified", "Reason" => "The borrower" <> _}} = out.(10_000, 720)

      assert {"Good", %{"Qualification" => "Not Qualified", "Reason" => "Debt to income ratio is too high."}} =
               out.(4_000, 720)

      assert {"Bad", %{"Qualification" => "Not Qualified", "Reason" => "Credit Score too low."}} = out.(10_000, 580)
    end

    test "ratios are computed from the file's own formulas", %{m: m, id: id} do
      r = m |> with_inputs(id, 10_000, 720) |> Eval.run()
      assert [{:ok, dti, _}, {:ok, "Sufficient", _}] = r[id.("Back End Ratio")].cells
      assert Decimal.equal?(dti, Decimal.new("0.21")), "(repayments 100 + expenses 2000) / income 10000"
      assert [{:ok, piti, _}, _] = r[id.("Front End Ratio")].cells

      assert Decimal.compare(piti, Decimal.new("0.0403")) in [:eq, :gt] and
               Decimal.compare(piti, Decimal.new("0.0404")) == :lt
    end

    test "export then import is lossless for everything it imported", %{m: m, r: r} do
      {:ok, m2, r2} = Dmn.from_xml(Dmn.to_xml(m, r.name))
      assert m2.nodes == m.nodes and Enum.sort(m2.edges) == Enum.sort(m.edges) and m2.types == m.types
      assert r2.dropped == %{} and r2.kept == %{}

      assert r2.converted == r.converted,
             "the invocations are kept as they were, so they are converted again on re-import"
    end
  end

  describe "review fixes" do
    alias DmnSpike.Dmn

    defp dmn(body),
      do: ~s|<definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="x">#{body}</definitions>|

    test "element ids that are not plain XML names are refused at import" do
      for bad <- [~s|a&quot; onmouseover=&quot;alert(1)&quot; x=&quot;|, "a b", "a&lt;b", "a&#39;b", "a/b"] do
        assert {:error, "invalid element id" <> _} =
                 Dmn.from_xml(dmn(~s|<decision id="#{bad}" name="N"><variable name="N"/></decision>|)),
               bad
      end

      for good <- ["n1", "_1CF5CEFA-AF97-46F9-9CD5-9A8AEBB20B4E", "dec.1", "é"] do
        assert {:ok, _, _} = Dmn.from_xml(dmn(~s|<decision id="#{good}" name="N"><variable name="N"/></decision>|)),
               good
      end
    end

    test "added nodes never reuse the id of an imported node" do
      {:ok, m, _} =
        Dmn.from_xml(
          dmn(
            ~s|<inputData id="n2" name="Imported"><variable name="Imported"/></inputData><inputData id="n3" name="Also"><variable name="Also"/></inputData>|
          )
        )

      {m, ids} =
        Enum.reduce(1..4, {m, []}, fn _, {m, ids} ->
          {m, id} = Model.add_node(m, "decision", 0, 0)
          {m, [id | ids]}
        end)

      assert length(Enum.uniq(ids)) == 4
      assert map_size(m.nodes) == 6
      assert m.nodes["n2"].name == "Imported" and m.nodes["n3"].name == "Also"
    end
  end

  describe "autocomplete cursor offsets are UTF-16 units" do
    alias DmnSpike.Autocomplete

    test "split and length agree with how the browser counts" do
      assert Autocomplete.utf16_length("a😀b") == 4
      assert Autocomplete.split_utf16("a😀b", 3) == {"a😀", "b"}
      assert Autocomplete.split_utf16("a😀b", 99) == {"a😀b", ""}
      assert Autocomplete.split_utf16("é日本", 2) == {"é日", "本"}
      assert Autocomplete.split_utf16("abc", 0) == {"", "abc"}
    end

    test "an emoji before the cursor does not shift the prefix" do
      m = Model.sample()
      # `"😀" = Fro + 1` with the cursor after "Fro": the browser reports 10 (the emoji counts as 2)
      text = ~s|"😀" = Fro + 1|
      caret = Autocomplete.utf16_length(~s|"😀" = Fro|)
      assert caret == 10
      {start, names} = Autocomplete.suggest(m, "back", 0, text, caret)
      assert "Front End Ratio" in names
      assert binary_part(text, start, byte_size("Fro")) == "Fro"

      {new, new_caret} =
        Autocomplete.accept(text, caret, start, names, Enum.find_index(names, &(&1 == "Front End Ratio")))

      assert new == ~s|"😀" = Front End Ratio + 1|
      assert new_caret == Autocomplete.utf16_length(~s|"😀" = Front End Ratio|)
      assert String.slice(new, 0..-5//1) |> String.ends_with?("Front End Ratio")
    end
  end

  describe "text annotations and associations" do
    alias DmnSpike.Dmn

    test "an annotation is created beside a node and joined to it" do
      {:ok, m, id} = Model.add_required(Model.sample(), "front", "annotation")
      assert m.nodes[id].type == :annotation and Model.artifact?(m.nodes[id])
      assert m.links == [{id, "front", :association}]
      assert m.edges == Model.sample().edges, "an association is not a requirement"
      assert Enum.any?(Model.edges_all(m), &(&1 == {id, "front", :association}))
      # evaluation ignores it
      assert Map.fetch!(Eval.run(m), id).value == nil
      assert Eval.run(m)["front"].value == Eval.run(Model.sample())["front"].value
      assert Model.pad_kinds(:annotation) == []
      assert "annotation" in Model.pad_kinds(:input)
    end

    test "connecting works in both directions, once, and an association is not a requirement" do
      {m, a} = Model.add_node(Model.sample(), "annotation", 10, 10)
      assert {:ok, m1} = Model.connect(m, a, "app")
      assert m1.links == [{a, "app", :association}]
      assert {:ok, m2} = Model.connect(m, "app", a)
      assert m2.links == [{a, "app", :association}], "stored annotation first"
      assert {:error, "already connected"} = Model.connect(m1, "app", a)
      assert {:error, "already connected"} = Model.connect(m1, a, "app")
    end

    test "deleting a node or an edge removes its links" do
      {:ok, m, id} = Model.add_required(Model.sample(), "front", "annotation")
      i = length(Model.edges_all(m)) - 1
      assert Model.delete_edge(m, i).links == []
      assert Model.delete_node(m, "front").links == []
      assert Model.delete_node(m, id).links == []
    end

    test "resizing keeps a minimum size" do
      {m, a} = Model.add_node(Model.sample(), "annotation", 100, 100)
      n = m.nodes[a]
      m = Model.resize(m, a, n.x + 300, n.y + 120)
      assert {m.nodes[a].w, m.nodes[a].h} == {300, 120}
      m = Model.resize(m, a, n.x + 5, n.y + 5)
      assert {m.nodes[a].w, m.nodes[a].h} == {60, 30}
    end

    test "a fresh export writes the annotation, the association and their diagram elements, and reads back" do
      {:ok, m, id} = Model.add_required(Model.sample(), "front", "annotation")
      m = Model.rename(m, id, "Check <this> & that")
      xml = Dmn.to_xml(m)
      assert xml =~ ~s|<textAnnotation id="#{id}">|
      assert xml =~ "<text>Check &lt;this&gt; &amp; that</text>"
      assert xml =~ ~s|<sourceRef href="#{"#" <> id}"/>|
      assert xml =~ ~s|<targetRef href="#front"/>|
      assert xml =~ ~s|dmnElementRef="_assoc-#{id}-front"|
      {:ok, m2, r} = Dmn.from_xml(xml)
      assert m2.nodes[id].name == "Check <this> & that"
      assert m2.links == [{id, "front", :association}]
      assert r.artifacts == %{annotation: 1} and r.nodes == 8
    end

    test "editing the annotation in a real file changes only that element" do
      {:ok, m, _} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      out = m |> Model.rename("_note", "Reviewed") |> Dmn.to_xml()
      assert out =~ "<text>Reviewed</text>"
      refute out =~ "Draft rules"
      assert out =~ ~s|<association id="_assoc">|, "the association keeps its own id"
      assert out =~ ~s|<knowledgeSource id="_bureau" name="Credit Bureau"/>|
      assert out =~ ~s|<authorityRequirement id="_a1">|
    end

    test "adding and removing links in a real file writes and drops the association" do
      {:ok, m, _} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      {:ok, m2} = Model.connect(m, "_note", "_risk")
      out = Dmn.to_xml(m2)
      assert out =~ ~s|<association id="_assoc">|
      assert out =~ ~s|<association id="_assoc-_note-_risk">|
      {:ok, m3, _} = Dmn.from_xml(out)

      assert Enum.sort(m3.links) == [
               {"_bureau", "_loan_d", :authority},
               {"_note", "_back", :association},
               {"_note", "_risk", :association}
             ]

      gone = m |> Model.delete_node("_note") |> Dmn.to_xml()
      refute gone =~ "textAnnotation"
      refute gone =~ "<association"
      refute gone =~ "_note"
    end

    test "a second association between the same two elements goes when the link goes" do
      xml = """
      <definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="d" id="d1">
        <inputData id="i" name="In"><variable id="i-v" name="In"/></inputData>
        <textAnnotation id="t"><text>x</text></textAnnotation>
        <association id="a1"><sourceRef href="#t"/><targetRef href="#i"/></association>
        <association id="a2"><sourceRef href="#i"/><targetRef href="#t"/></association>
      </definitions>
      """

      {:ok, m, _} = Dmn.from_xml(xml)
      assert m.links == [{"t", "i", :association}]
      out = Dmn.to_xml(m)
      assert out =~ ~s|<association id="a1">| and out =~ ~s|<association id="a2">|, "untouched, both stay"

      gone = m |> Model.delete_edge(length(m.edges)) |> Dmn.to_xml()
      refute gone =~ "<association"
    end

    test "an association to an element that does not exist stays in the file" do
      xml = """
      <definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="d" id="d1">
        <textAnnotation id="t"><text>x</text></textAnnotation>
        <association id="a"><sourceRef href="#t"/><targetRef href="#ghost"/></association>
      </definitions>
      """

      {:ok, m, r} = Dmn.from_xml(xml)
      assert m.links == []
      assert r.kept["association to an unknown element"] == 1
      assert Dmn.to_xml(m) =~ ~s|<association id="a">|
    end
  end

  describe "knowledge sources and authority requirements" do
    alias DmnSpike.Dmn

    test "what may require what" do
      m = Model.sample()
      {m, s} = Model.add_node(m, "source", 10, 10)
      assert m.nodes[s].type == :source and Model.artifact?(m.nodes[s])

      # a source takes its authority from an input, decision or source; decisions and BKMs may require a source
      assert {:ok, m1} = Model.connect(m, "app", s)
      assert {:ok, m2} = Model.connect(m, "front", s)
      assert m2.links == [{"front", s, :authority}]
      assert {:ok, m3} = Model.connect(m, s, "loan")
      assert m3.links == [{s, "loan", :authority}]
      assert {:ok, m4} = Model.connect(m, s, "dti")
      assert m4.links == [{s, "dti", :authority}]
      assert {:error, _} = Model.connect(m, s, "app"), "an input requires nothing"
      assert {:error, _} = Model.connect(m, "dti", s), "a BKM is not an authority for a source"
      assert {:error, "already connected"} = Model.connect(m1, "app", s)
      {m5, s2} = Model.add_node(m, "source", 300, 10)
      assert {:ok, m6} = Model.connect(m5, s, s2)
      assert {:error, "that would create a cycle"} = Model.connect(m6, s2, s)
      assert m.edges == Model.sample().edges, "authority links are not evaluated requirements"
    end

    test "the pad offers sources and the sources' own pad offers what they need" do
      assert "source" in Model.pad_kinds(:decision) and "source" in Model.pad_kinds(:bkm)
      assert Model.pad_kinds(:input) == ["annotation"]
      assert Model.pad_kinds(:source) == ["input", "decision", "source", "annotation"]
      {:ok, m, s} = Model.add_required(Model.sample(), "loan", "source")
      assert m.links == [{s, "loan", :authority}]
      {:ok, m, i} = Model.add_required(m, s, "input")
      assert m.links |> Enum.member?({i, s, :authority})
    end

    test "sources do not take part in evaluation or the FEEL scope" do
      {:ok, m, s} = Model.add_required(Model.sample(), "front", "source")
      assert Eval.run(m)["front"].value == Eval.run(Model.sample())["front"].value
      assert Eval.run(m)[s].value == nil
      assert s not in Model.scope_names(m, "front", 0)
    end

    test "authority requirements are written into the requiring element and read back" do
      {:ok, m, s} = Model.add_required(Model.sample(), "loan", "source")
      m = Model.rename(m, s, "Credit Bureau")
      {:ok, m} = Model.connect(m, "app", s)
      xml = Dmn.to_xml(m)
      assert xml =~ ~s|<knowledgeSource id="#{s}" name="Credit Bureau">|
      assert xml =~ ~s|<requiredInput href="#app"/>|, "the source requires the input"
      assert xml =~ ~s|<requiredAuthority href="#{"#" <> s}"/>|, "the decision requires the source"
      {:ok, m2, r} = Dmn.from_xml(xml)
      assert Enum.sort(m2.links) == Enum.sort(m.links)
      assert r.artifacts == %{source: 1}
    end

    test "in a real file an untouched authority requirement keeps its id when its decision is edited" do
      {:ok, m, _} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      out = m |> Model.rename("_loan_d", "Loan Decision 2") |> Dmn.to_xml()
      assert out =~ ~s|<authorityRequirement id="_a1">|
      assert out =~ ~s|<requiredAuthority href="#_bureau"/>|
      assert out =~ ~s|<decision id="_loan_d" name="Loan Decision 2">|
    end

    test "connecting and removing in a real file" do
      {:ok, m, _} = Dmn.from_xml(File.read!("test/fixtures/kie_sample.dmn"))
      {:ok, m2} = Model.connect(m, "_app", "_bureau")
      out = Dmn.to_xml(m2)
      assert out =~ ~s|<knowledgeSource id="_bureau" name="Credit Bureau">|
      assert out =~ ~s|<requiredInput href="#_app"/>|
      {:ok, m3, _} = Dmn.from_xml(out)
      assert {"_app", "_bureau", :authority} in m3.links and {"_bureau", "_loan_d", :authority} in m3.links

      gone = m |> Model.delete_node("_bureau") |> Dmn.to_xml()
      refute gone =~ "knowledgeSource"
      refute gone =~ "authorityRequirement"
      refute gone =~ "_bureau"
    end

    test "renaming and describing a source rewrites only that element and keeps its other children" do
      xml = """
      <definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="d" id="d1">
        <knowledgeSource id="k" name="Old">
          <description>Keep</description>
          <type>Regulation</type>
          <locationURI>http://example.org/law</locationURI>
        </knowledgeSource>
      </definitions>
      """

      {:ok, m, r} = Dmn.from_xml(xml)
      assert r.nodes == 0 and r.artifacts == %{source: 1}
      out = m |> Model.rename("k", "Law") |> Model.set_description("k", "Changed") |> Dmn.to_xml()
      assert out =~ ~s|<knowledgeSource id="k" name="Law">|
      assert out =~ "<description>Changed</description>"
      assert out =~ "<type>Regulation</type>"
      assert out =~ "<locationURI>http://example.org/law</locationURI>"
    end
  end

  describe "groups" do
    alias DmnSpike.Dmn

    defp group_around(m, ids) do
      ns = Enum.map(ids, &m.nodes[&1])
      x = Enum.min(Enum.map(ns, & &1.x)) - 20
      y = Enum.min(Enum.map(ns, & &1.y)) - 40
      {m, g} = Model.add_node(m, "group", 0, 0)

      m =
        put_in(m.nodes[g], %{
          m.nodes[g]
          | x: x,
            y: y,
            w: Enum.max(Enum.map(ns, &(&1.x + &1.w))) + 20 - x,
            h: Enum.max(Enum.map(ns, &(&1.y + &1.h))) + 20 - y
        })

      {m, g}
    end

    test "a group knows what is inside it, and moving it moves them" do
      {m, g} = group_around(Model.sample(), ["app", "prod"])
      assert Enum.sort(Model.members(m, g)) == ["app", "prod"]
      before = Map.new(m.nodes, fn {k, n} -> {k, {n.x, n.y}} end)
      {gx, gy} = before[g]
      m2 = Model.move(m, g, gx + 50, gy - 30)

      for k <- [g, "app", "prod"] do
        {x, y} = before[k]
        assert {m2.nodes[k].x, m2.nodes[k].y} == {x + 50, y - 30}, k
      end

      assert {m2.nodes["front"].x, m2.nodes["front"].y} == before["front"], "elements outside stay"
      # moving a plain node does not drag anything
      m3 = Model.move(m, "app", 0, 0)
      assert {m3.nodes["prod"].x, m3.nodes["prod"].y} == before["prod"]
    end

    test "a group is not evaluated, has no pad and cannot be connected" do
      {m, g} = group_around(Model.sample(), ["app"])
      assert Eval.run(m)["front"].value == Eval.run(Model.sample())["front"].value
      assert Model.pad_kinds(:group) == []
      assert {:error, _} = Model.connect(m, g, "front")
      assert {:error, _} = Model.connect(m, "app", g)
      assert Model.artifact?(m.nodes[g])
    end

    test "a fresh export writes the group and its shape, and reads back" do
      {m, g} = group_around(Model.sample(), ["app", "prod"])
      m = Model.rename(m, g, "Inputs")
      xml = Dmn.to_xml(m)
      assert xml =~ ~s|<group id="#{g}" name="Inputs"/>|
      assert xml =~ ~s|dmnElementRef="#{g}"|
      {:ok, m2, r} = Dmn.from_xml(xml)
      assert m2.nodes[g].type == :group and m2.nodes[g].name == "Inputs"
      assert r.artifacts == %{group: 1}
      assert Enum.sort(Model.members(m2, g)) == ["app", "prod"]
    end

    test "in a real file a group keeps its documentation, and a new one is added in the file's prefixes" do
      xml = """
      <dmn:definitions xmlns:dmn="https://www.omg.org/spec/DMN/20240513/MODEL/" xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/" xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/" name="d" id="d1">
        <dmn:inputData id="i" name="In"><dmn:variable id="i-v" name="In"/></dmn:inputData>
        <dmn:group id="g" name="Old"><dmn:documentation>Notes</dmn:documentation></dmn:group>
        <dmndi:DMNDI>
          <dmndi:DMNDiagram id="dg">
            <dmndi:DMNShape id="si" dmnElementRef="i"><dc:Bounds x="40" y="40" width="150" height="60"/></dmndi:DMNShape>
            <dmndi:DMNShape id="sg" dmnElementRef="g"><dc:Bounds x="10" y="10" width="300" height="200"/></dmndi:DMNShape>
          </dmndi:DMNDiagram>
        </dmndi:DMNDI>
      </dmn:definitions>
      """

      {:ok, m, r} = Dmn.from_xml(xml)
      assert r.artifacts == %{group: 1} and r.nodes == 1
      assert Model.members(m, "g") == ["i"]
      assert parse_xml(Dmn.to_xml(m)) == parse_xml(xml), "untouched"

      out = m |> Model.rename("g", "New") |> Dmn.to_xml()
      assert out =~ ~s|<dmn:group id="g" name="New">|
      assert out =~ "<dmn:documentation>Notes</dmn:documentation>"

      out = m |> Model.move("g", 100, 100) |> Dmn.to_xml()
      assert out =~ ~s|<dc:Bounds x="100" y="100" width="300" height="200"/>|
      assert out =~ ~s|<dc:Bounds x="130" y="130" width="150" height="60"/>|, "the contained input moved with it"

      {m2, n} = Model.add_node(m, "group", 500, 500)
      out = Dmn.to_xml(m2)
      assert out =~ ~s|<dmn:group id="#{n}" name="New group"/>|
    end
  end

  describe "review fixes (types, tables, names, XML order)" do
    alias DmnSpike.{Dmn, Editor, Svg}

    test "a type that became a scalar does not keep exporting its old components" do
      m = Model.sample()
      app = Enum.find_index(m.types, &(&1.name == "tApplicant"))
      assert Enum.at(m.types, app).components != []
      m = %{m | types: List.update_at(m.types, app, &%{&1 | ref: "string"})}
      xml = Dmn.to_xml(m)
      {:ok, m2, _} = Dmn.from_xml(xml)
      t = Enum.at(m2.types, app)
      assert t.ref == "string" and t.components == [], "still a string after a round trip"

      assert xml =~
               ~r/<itemDefinition id="_t#{app}" name="tApplicant">\s*<typeRef>string<\/typeRef>\s*<\/itemDefinition>/
    end

    test "children are written in schema order: description before extensionElements; no test value in an input" do
      m = Model.set_description(Model.sample(), "app", "Who applies")
      m = Model.set_text(m, "app", 0, "{Income: 1}")
      xml = Dmn.to_xml(m)

      assert xml =~ ~r/<inputData id="app".*?<description>Who applies<\/description>\s*<variable/s
      refute xml =~ "spike:value", "the value belongs to a scenario, not to the file"

      xml = """
      <definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="d" id="d1">
        <knowledgeSource id="k" name="K">
          <description>D</description>
          <extensionElements/>
          <authorityRequirement id="r"><requiredAuthority href="#k"/></authorityRequirement>
          <type>Law</type>
          <owner href="#x"/>
        </knowledgeSource>
        <decision id="d" name="D">
          <description>x</description>
          <extensionElements/>
          <variable id="v" name="D"/>
          <literalExpression><text>1</text></literalExpression>
        </decision>
      </definitions>
      """

      {:ok, m, _} = Dmn.from_xml(xml)
      out = m |> Model.rename("k", "K2") |> Model.rename("d", "D2") |> Dmn.to_xml()

      assert out =~
               ~r/<description>D<\/description>\s*<extensionElements\/>\s*<authorityRequirement.*<type>Law<\/type>\s*<owner/s

      assert out =~ ~r/<description>x<\/description>\s*<extensionElements\/>\s*<variable/
    end

    test "names are found however many exist" do
      m = Enum.reduce(1..120, %Model{}, fn _, acc -> acc |> Model.add_node("decision", 0, 0) |> elem(0) end)
      names = m.nodes |> Map.values() |> Enum.map(& &1.name)
      assert length(Enum.uniq(names)) == 120
    end

    test "named output headers have a table path the editor understands" do
      assert Editor.table_path("n-0") == ["n", 0]
      assert Editor.table_path("e-1-2") == ["e", 1, 2]
      assert Editor.table_path("h-0") == ["h", 0]
      m = Model.sample()
      m = Model.set_table_text(m, "risk", Editor.table_path("n-0"), "Category")
      assert hd(m.nodes["risk"].expr.outputs).name == "Category"
    end

    test "value badges are escaped as HTML" do
      html = Svg.node_value_html(%{value: "<svg/onload=a=1>"})
      refute html =~ "<"
      assert html =~ "&lt;svg"
    end

    test "only a decision can become a decision table" do
      m = Model.sample()
      assert Model.set_expr_kind(m, "dti", :table) == m
      assert Model.set_expr_kind(m, "app", :table) == m
      assert Model.kind(Model.set_expr_kind(m, "front", :table).nodes["front"]) == :table
    end

    test "COLLECT and RULE ORDER with no matching rule give an empty list, other policies null" do
      {m, id} = Model.add_node(Model.sample(), "decision", 0, 0)
      m = Model.set_expr_kind(m, id, :table)
      m = Model.set_table_text(m, id, ["h", 0], "1")
      m = Model.set_table_text(m, id, ["e", 0, 0], "< 0")
      m = Model.set_table_text(m, id, ["o", 0, 0], ~s|"x"|)

      for {policy, expected} <- [{"COLLECT", []}, {"RULE ORDER", []}, {"UNIQUE", nil}, {"FIRST", nil}, {"ANY", nil}] do
        r = m |> Model.set_hit_policy(id, policy) |> Eval.run() |> Map.fetch!(id)
        assert r.value == expected, policy
      end
    end

    test "date, time and duration types accept only their own values" do
      {:ok, dt, _} = Feel.eval(~s|date and time("2020-01-01T10:00:00")|, %{}, sandbox: false)
      {:ok, time, _} = Feel.eval(~s|time("10:00:00")|, %{}, sandbox: false)
      {:ok, days, _} = Feel.eval(~s|duration("P1DT2H")|, %{}, sandbox: false)
      {:ok, months, _} = Feel.eval(~s|duration("P1Y2M")|, %{}, sandbox: false)
      {:ok, date, _} = Feel.eval(~s|date("2020-01-01")|, %{}, sandbox: false)
      m = Model.sample()

      for {type, good} <- [
            {"date and time", dt},
            {"time", time},
            {"days and time duration", days},
            {"years and months duration", months},
            {"date", date}
          ] do
        assert Types.validate(m, good, type) == [], type
        assert Types.validate(m, "not a value", type) != [], type
      end

      assert Types.validate(m, days, "years and months duration") != []
      assert Types.validate(m, dt, "date") != []
      assert Types.validate(m, date, "context") != [], "a date is not a context"
    end
  end

  describe "review round two (fidelity and semantics)" do
    alias DmnSpike.Dmn

    @ns ~s|xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="d" id="d1"|
    defp doc(body), do: ~s|<definitions #{@ns}>#{body}</definitions>|
    defp import_xml!(xml), do: Dmn.from_xml(xml) |> then(fn {:ok, m, r} -> {m, r} end)

    test "a business knowledge model writes its logic before its requirements" do
      {:ok, m, a} = Model.add_required(Model.sample(), "dti", "bkm")
      {:ok, m, _} = Model.add_required(m, "dti", "source")
      xml = Dmn.to_xml(m)
      [bkm] = Regex.run(~r/<businessKnowledgeModel id="dti".*?<\/businessKnowledgeModel>/s, xml)
      at = fn tag -> bkm |> :binary.match("<" <> tag) |> elem(0) end
      assert at.("encapsulatedLogic") < at.("knowledgeRequirement")
      assert at.("encapsulatedLogic") < at.("authorityRequirement")
      assert a
    end

    test "an empty literal expression opens and evaluates" do
      {m, _} =
        import_xml!(doc(~s|<decision id="a" name="A"><variable id="v" name="A"/><literalExpression/></decision>|))

      assert m.nodes["a"].expr.result == ""
      assert Eval.run(m)["a"].value == nil
    end

    test "a context with no result entry is the context itself, and is written without one" do
      xml =
        doc("""
        <decision id="a" name="A"><variable id="v" name="A"/>
          <context><contextEntry><variable name="x"/><literalExpression><text>1</text></literalExpression></contextEntry></context>
        </decision>
        <decision id="b" name="B"><variable id="w" name="B"/>
          <informationRequirement id="r"><requiredDecision href="#a"/></informationRequirement>
          <literalExpression><text>A.x + 1</text></literalExpression>
        </decision>
        """)

      {m, _} = import_xml!(xml)
      r = Eval.run(m)
      assert r["a"].value == %{"x" => Decimal.new(1)}
      assert Decimal.equal?(r["b"].value, 2)
      out = m |> Model.set_text("a", 0, "2") |> Dmn.to_xml()
      assert length(Regex.scan(~r/<contextEntry/, out)) == 1, "no empty result entry was added"
    end

    test "an aggregated COLLECT table is kept read-only instead of being evaluated as a plain COLLECT" do
      xml =
        doc("""
        <decision id="a" name="A"><variable id="v" name="A"/>
          <decisionTable hitPolicy="COLLECT" aggregation="SUM"><output id="o"/>
            <rule><outputEntry><text>2</text></outputEntry></rule><rule><outputEntry><text>3</text></outputEntry></rule>
          </decisionTable>
        </decision>
        """)

      {m, r} = import_xml!(xml)
      assert %{kind: :raw, tag: "decisionTable with aggregation SUM"} = m.nodes["a"].expr
      assert r.kept["a: decisionTable with aggregation SUM expression, read-only"] == 1 or map_size(r.kept) > 0
      assert Eval.run(m)["a"].value == nil
      assert Dmn.to_xml(m) =~ ~s|aggregation="SUM"|
    end

    test "a requirement with a description before its reference keeps its id when the decision is renamed" do
      xml =
        doc("""
        <inputData id="i" name="In"><variable id="iv" name="In"/></inputData>
        <decision id="a" name="A"><variable id="v" name="A"/>
          <informationRequirement id="keep"><description>why</description><requiredInput href="#i"/></informationRequirement>
          <literalExpression><text>In</text></literalExpression>
        </decision>
        """)

      {m, _} = import_xml!(xml)
      out = m |> Model.rename("a", "A2") |> Dmn.to_xml()
      assert out =~ ~s|<informationRequirement id="keep">|
      assert out =~ "<description>why</description>"
      refute out =~ "_req-i-a"
    end

    test "text mixed with elements survives untouched" do
      xml =
        doc("""
        <inputData id="i" name="In"><variable id="iv" name="In"/>
          <extensionElements><note>Hello <b>big</b> world!</note></extensionElements>
        </inputData>
        """)

      {m, _} = import_xml!(xml)
      assert Dmn.to_xml(m) =~ "<note>Hello <b>big</b> world!</note>"
      assert m |> Model.rename("i", "In2") |> Dmn.to_xml() =~ "<note>Hello <b>big</b> world!</note>"
    end

    test "renaming a type keeps its element, and preserved references follow the new name" do
      {m, _} = import_xml!(File.read!("test/fixtures/Sample.dmn"))
      i = Enum.find_index(m.types, &(&1.name == "Credit_Score_Rating"))
      original = File.read!("test/fixtures/Sample.dmn")
      [_, id] = Regex.run(~r/<dmn:itemDefinition id="([^"]+)"[^>]*name="Credit_Score_Rating"/, original) || [nil, nil]
      assert id
      out = m |> Types.rename_top(i, "Score_Band") |> Dmn.to_xml()
      assert out =~ ~r/<dmn:itemDefinition id="#{id}"[^>]*name="Score_Band"/, "same element, same id"
      refute out =~ ~s|"Credit_Score_Rating"|, "no reference to the old name is left"
      refute out =~ ">Credit_Score_Rating<"
      {:ok, m2, _} = Dmn.from_xml(out)
      assert Enum.any?(m2.types, &(&1.name == "Score_Band"))
      assert m2.nodes |> Map.values() |> Enum.all?(&(&1.type_ref != "Credit_Score_Rating"))
    end

    test "a variable keeps its own description and extensions when its node is renamed" do
      xml =
        doc("""
        <decision id="a" name="A">
          <variable id="v" name="A"><description>var doc</description><extensionElements><x/></extensionElements></variable>
          <literalExpression><text>1</text></literalExpression>
        </decision>
        """)

      {m, _} = import_xml!(xml)
      out = m |> Model.rename("a", "A2") |> Dmn.to_xml()
      assert out =~ ~s|<variable id="v" name="A2">|
      assert out =~ "<description>var doc</description>"
      assert out =~ "<extensionElements>"
    end

    test "editing a table cell keeps the ids, typeRefs and unknown children of the table" do
      original = File.read!("test/fixtures/Sample.dmn")
      {m, _} = import_xml!(original)
      id = Enum.find_value(m.nodes, fn {k, n} -> if n.name == "Loan Pre-Qualification", do: k end)
      out = m |> Model.set_table_text(id, ["e", 0, 0], ~s|"Poor"|) |> Dmn.to_xml()

      ids = fn xml -> Regex.scan(~r/\bid="([^"]+)"/, xml) |> Enum.map(&List.last/1) |> Enum.sort() end
      refs = fn xml -> Regex.scan(~r/typeRef="([^"]+)"/, xml) |> Enum.map(&List.last/1) |> Enum.sort() end
      assert refs.(out) == refs.(original), "typeRefs of the table's columns are still there"
      assert ids.(out) == ids.(original), "no id was lost or invented"
    end

    test "editing a business knowledge model body keeps its formal parameters' ids and types" do
      xml =
        doc("""
        <businessKnowledgeModel id="k" name="K"><variable id="kv" name="K"/>
          <encapsulatedLogic id="el"><formalParameter id="p1" name="x" typeRef="number"/>
            <literalExpression id="le"><text>x + 1</text></literalExpression></encapsulatedLogic>
        </businessKnowledgeModel>
        """)

      {m, _} = import_xml!(xml)
      out = m |> Model.set_text("k", 0, "x + 2") |> Dmn.to_xml()
      assert out =~ ~s|<formalParameter id="p1" name="x" typeRef="number"/>|
      assert out =~ ~s|<encapsulatedLogic id="el">|
      assert out =~ ~s|<literalExpression id="le">|
      assert out =~ "x + 2"
    end

    test "only our own value element counts as a test value, not another vendor's" do
      xml =
        ~s|<definitions #{@ns} xmlns:p="urn:popcorn-dmn-spike" xmlns:v="urn:vendor"><inputData id="i" name="In"><variable id="iv" name="In"/><extensionElements><v:value>vendor data</v:value></extensionElements></inputData><inputData id="j" name="Jn"><variable id="jv" name="Jn"/><extensionElements><v:value>vendor</v:value><p:value>mine</p:value></extensionElements></inputData></definitions>|

      {m, _} = import_xml!(xml)
      assert m.nodes["i"].expr.result == ""
      assert m.nodes["j"].expr.result == "mine"
      out = m |> Model.rename("i", "In2") |> Dmn.to_xml()
      assert out =~ "<v:value>vendor data</v:value>", "the vendor element is kept"
    end

    test "a test value saved into the file by an earlier version becomes the first scenario and is dropped on save" do
      xml =
        ~s|<definitions #{@ns} xmlns:p="urn:popcorn-dmn-spike"><inputData id="i" name="In"><variable id="iv" name="In"/><extensionElements><p:value>1</p:value><other xmlns="urn:x"/></extensionElements></inputData></definitions>|

      {m, _} = import_xml!(xml)
      assert m.nodes["i"].expr.result == "1", "the old value is the input's value now"
      assert [%{name: "Scenario 1"}] = m.scenarios

      # saving without any edit still drops it, whatever the prefix, and keeps the other extension content
      out = Dmn.to_xml(m)
      refute out =~ "p:value"
      assert out =~ ~s|<other xmlns="urn:x"/>|
      {m2, _} = import_xml!(out)
      assert m2.nodes["i"].expr.result == ""
    end

    test "an expression constraint on a list constrains the whole list; enumerations still check each item" do
      m = Model.sample()

      list = %{
        name: "tList",
        ref: "number",
        collection: true,
        constraint: %{kind: :expression, text: "count(?) > 1"},
        components: []
      }

      m = %{m | types: m.types ++ [list]}
      two = [Decimal.new(1), Decimal.new(2)]
      assert Types.validate(m, two, "tList") == []
      assert Types.validate(m, [Decimal.new(1)], "tList") != []
      assert Types.validate(m, [], "tList") != [], "an empty list does not bypass it"
      assert Types.validate(m, ["a", "b"], "tList") != [], "items must still be numbers"

      each = %{list | name: "tEach", constraint: %{kind: :range, text: "[0..5]"}}
      m = %{m | types: m.types ++ [each]}
      assert Types.validate(m, [Decimal.new(1), Decimal.new(9)], "tEach") != []
      assert Types.validate(m, [Decimal.new(1)], "tEach") == []
    end
  end

  describe "review round three (ids, merge order, diagram)" do
    alias DmnSpike.Dmn

    @ns3 ~s|xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/" xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/" xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/" name="d" id="d1"|
    defp doc3(body), do: ~s|<definitions #{@ns3}>#{body}</definitions>|
    defp import3!(xml), do: Dmn.from_xml(xml) |> then(fn {:ok, m, _} -> m end)
    defp all_ids(xml), do: Regex.scan(~r/\bid="([^"]+)"/, xml) |> Enum.map(&List.last/1)

    @table3 """
    <decision id="a" name="A"><variable id="v" name="A"/>
      <decisionTable id="dt" hitPolicy="FIRST">
        <input id="i1"><inputExpression id="ie" typeRef="number"><text>1</text></inputExpression><inputValues id="iv"><text>1,2</text></inputValues></input>
        <output id="o1" name="r"><outputValues id="ov"><text>"x","y"</text></outputValues></output>
        <rule id="r1"><inputEntry id="e1"><text>1</text></inputEntry><outputEntry id="oe1"><text>"x"</text></outputEntry></rule>
        <rule id="r2"><inputEntry id="e2"><text>2</text></inputEntry><outputEntry id="oe2"><text>"y"</text></outputEntry></rule>
      </decisionTable>
    </decision>
    """

    test "a new node never takes an id the document already uses for something else" do
      m = import3!(doc3(~s|<inputData id="i" name="In"><variable id="n1" name="In"/></inputData>|))
      {m, id} = Model.add_node(m, "decision", 10, 10)
      refute id == "n1"
      ids = all_ids(Dmn.to_xml(m))
      assert ids == Enum.uniq(ids), "every id in the exported document is unique"

      # also against ids generated for a node: n2's variable would be n2-var
      m = import3!(doc3(~s|<inputData id="i" name="In"><variable id="n1-var" name="In"/></inputData>|))
      {_, id} = Model.add_node(m, "decision", 10, 10)
      refute id == "n1"
    end

    test "editing a table cell keeps what an output and an input hold besides their text" do
      m = import3!(doc3(@table3))
      out = m |> Model.set_table_text("a", ["e", 0, 0], "2") |> Dmn.to_xml()
      assert out =~ ~s|<outputValues id="ov">|
      assert out =~ ~s|<inputValues id="iv">|

      assert out =~ ~r/<inputExpression id="ie" typeRef="number">.*<\/inputExpression>\s*<inputValues/s,
             "inputValues stays after inputExpression, as the schema says"
    end

    test "what the model removes does not come back: the last rule, all parameters" do
      m = import3!(doc3(@table3))
      m = Model.del_rule(m, "a", 1)
      m = Model.del_rule(m, "a", 0)
      out = Dmn.to_xml(m)
      refute out =~ "<rule", "deleting every rule leaves none"
      assert out =~ ~s|<outputValues id="ov">|, "unmodelled children are still kept"

      bkm =
        doc3(
          ~s|<businessKnowledgeModel id="k" name="K"><variable id="kv" name="K"/><encapsulatedLogic id="el"><formalParameter id="p1" name="x"/><literalExpression id="le"><text>1</text></literalExpression></encapsulatedLogic></businessKnowledgeModel>|
        )

      m = import3!(bkm)
      out = m |> Model.set_params("k", "") |> Model.set_text("k", 0, "2") |> Dmn.to_xml()
      refute out =~ "<formalParameter"
      assert out =~ ~s|<encapsulatedLogic id="el">|
    end

    test "turning a context into a decision table leaves no diagram reference to the removed ids" do
      m = import3!(File.read!("test/fixtures/Sample.dmn"))
      id = Enum.find_value(m.nodes, fn {k, n} -> if n.name == "Front End Ratio", do: k end)
      assert Model.kind(m.nodes[id]) == :context
      out = m |> Model.set_expr_kind(id, :table) |> Dmn.to_xml()
      ids = MapSet.new(all_ids(out))
      refs = Regex.scan(~r/dmnElementRef="([^"]+)"/, out) |> Enum.map(&List.last/1)

      assert Enum.all?(refs, &MapSet.member?(ids, &1)),
             "dangling: #{inspect(Enum.reject(refs, &MapSet.member?(ids, &1)))}"
    end

    test "a requirement without an id gets one, and the diagram edge refers to it" do
      xml =
        doc3("""
        <inputData id="i" name="In"><variable id="iv" name="In"/></inputData>
        <decision id="a" name="A"><variable id="v" name="A"/>
          <informationRequirement><requiredInput href="#i"/></informationRequirement>
          <literalExpression><text>In</text></literalExpression>
        </decision>
        """)

      m = import3!(xml)
      out = m |> Model.move("a", 300, 300) |> Dmn.to_xml()
      ids = MapSet.new(all_ids(out))
      refs = Regex.scan(~r/dmnElementRef="([^"]+)"/, out) |> Enum.map(&List.last/1)
      assert Enum.any?(refs, &String.starts_with?(&1, "_auto-")), "there is an edge for the requirement"
      assert Enum.all?(refs, &MapSet.member?(ids, &1)), "and it refers to an element that exists"
    end

    test "new DRG elements go before the artifacts, new artifacts after the DRG elements" do
      m = import3!(File.read!("test/fixtures/kie_sample.dmn"))
      {m, d} = Model.add_node(m, "decision", 10, 10)
      {m, a} = Model.add_node(m, "annotation", 10, 10)
      {m, g} = Model.add_node(m, "group", 10, 10)
      out = Dmn.to_xml(m)
      at = fn id -> out |> :binary.match(~s|id="#{id}"|) |> elem(0) end
      assert at.(d) < at.("_note"), "the new decision is before the existing annotation"
      assert at.("_bureau") < at.(a) and at.("_loan_d") < at.(g), "artifacts follow the DRG elements"

      fresh = Model.sample() |> then(fn m -> m |> Model.add_node("annotation", 5, 5) |> elem(0) end) |> Dmn.to_xml()

      assert :binary.match(fresh, "<textAnnotation") |> elem(0) >
               :binary.match(fresh, ~s|<decision id="risk"|) |> elem(0)
    end

    test "a description on an annotation or a group is written and read back" do
      {m, a} = Model.add_node(Model.sample(), "annotation", 5, 5)
      {m, g} = Model.add_node(m, "group", 5, 5)
      m = m |> Model.set_description(a, "about the note") |> Model.set_description(g, "about the group")
      {:ok, m2, _} = m |> Dmn.to_xml() |> Dmn.from_xml()
      assert m2.nodes[a].description == "about the note" and m2.nodes[g].description == "about the group"
    end

    test "a moved edge keeps its style before the waypoints and its label after them" do
      xml =
        doc3("""
        <inputData id="i" name="In"><variable id="iv" name="In"/></inputData>
        <decision id="a" name="A"><variable id="v" name="A"/>
          <informationRequirement id="r"><requiredInput href="#i"/></informationRequirement>
          <literalExpression><text>In</text></literalExpression>
        </decision>
        <dmndi:DMNDI><dmndi:DMNDiagram id="dg">
          <dmndi:DMNShape id="s1" dmnElementRef="i"><dc:Bounds x="0" y="100" width="150" height="60"/></dmndi:DMNShape>
          <dmndi:DMNShape id="s2" dmnElementRef="a"><dc:Bounds x="0" y="0" width="150" height="60"/></dmndi:DMNShape>
          <dmndi:DMNEdge id="e" dmnElementRef="r">
            <dmndi:DMNStyle strokeColor="red"/>
            <di:waypoint x="75" y="100"/><di:waypoint x="75" y="60"/>
            <dmndi:DMNLabel><dmndi:Text>why</dmndi:Text></dmndi:DMNLabel>
          </dmndi:DMNEdge>
        </dmndi:DMNDiagram></dmndi:DMNDI>
        """)

      out = xml |> import3!() |> Model.move("a", 400, 0) |> Dmn.to_xml()
      [edge] = Regex.run(~r/<dmndi:DMNEdge.*?<\/dmndi:DMNEdge>/s, out)
      at = fn tag -> edge |> :binary.match(tag) |> elem(0) end
      assert at.("<dmndi:DMNStyle") < at.("<di:waypoint")
      assert at.("<di:waypoint") < at.("<dmndi:DMNLabel")
    end
  end

  describe "problems" do
    alias DmnSpike.{Dmn, Problems}

    defp problems(m), do: Problems.list(m, Eval.run(m))

    test "a clean model has none" do
      assert problems(Model.sample()) == []
      assert Problems.summary([]) == {"✓ No problems", "ok"}
    end

    test "the real Sample only has the warning that no rule matches yet (it has no input values)" do
      {:ok, m, _} = Dmn.from_xml(File.read!("test/fixtures/Sample.dmn"))
      assert [%{severity: :warning, message: "no rule matches the current input"}] = problems(m)
    end

    test "a FEEL error in a cell names the node and the cell" do
      m = Model.set_text(Model.sample(), "front", 0, "1 +")
      assert [%{severity: :error, target: {:node, "front"}, title: "Front End Ratio", message: msg}] = problems(m)
      assert msg =~ "pmt:"
    end

    test "a value that breaks its type is an error on the node" do
      m = Model.sample()
      i = Enum.find_index(m.types, &(&1.name == "tRatio"))
      types = List.update_at(m.types, i, &%{&1 | constraint: %{kind: :range, text: "[0..20]"}})
      found = problems(%{m | types: types})
      assert Enum.any?(found, &(&1.target == {:node, "front"} and &1.message =~ "does not fit its type"))
    end

    test "an empty, unconnected decision is a warning twice over" do
      {m, id} = Model.add_node(Model.sample(), "decision", 10, 10)
      found = problems(m) |> Enum.filter(&(&1.target == {:node, id}))
      assert Enum.map(found, & &1.message) |> Enum.sort() == ["has no expression yet", "is not connected to anything"]
      assert Enum.all?(found, &(&1.severity == :warning))
      assert {"⚠ 2 warnings", "warn"} = Problems.summary(found)
    end

    test "decision tables: no match is a warning, two matches under UNIQUE an error, a broken entry an error" do
      m = Model.sample()
      m = Model.set_table_text(m, "risk", ["e", 0, 0], "> 1000")
      m = Model.set_table_text(m, "risk", ["e", 1, 0], "> 1000")
      m = Model.set_table_text(m, "risk", ["e", 2, 0], "> 1000")
      found = problems(m) |> Enum.filter(&(&1.target == {:node, "risk"}))
      assert Enum.any?(found, &(&1.severity == :warning and &1.message =~ "no rule matches"))

      m = Model.set_hit_policy(Model.sample(), "risk", "UNIQUE")
      m = Model.set_table_text(m, "risk", ["e", 0, 0], "-")
      m = Model.set_table_text(m, "risk", ["e", 1, 0], "-")
      m = Model.set_table_text(m, "risk", ["e", 0, 1], "-")
      found = problems(m) |> Enum.filter(&(&1.target == {:node, "risk"}))
      assert Enum.any?(found, &(&1.severity == :error and &1.message =~ "UNIQUE"))

      m = Model.set_table_text(Model.sample(), "risk", ["e", 0, 0], "< <")
      found = problems(m) |> Enum.filter(&(&1.target == {:node, "risk"}))
      assert Enum.any?(found, &(&1.severity == :error and &1.message =~ "rule 1, input 1"))
    end

    test "an invalid constraint is a problem of the type, nested components included" do
      m = Model.sample()
      i = Enum.find_index(m.types, &(&1.name == "tApplicant"))

      types =
        List.update_at(m.types, i, fn t ->
          %{t | components: List.update_at(t.components, 0, &%{&1 | constraint: %{kind: :expression, text: "(("}})}
        end)

      found = Problems.list(%{m | types: types}, Eval.run(m))
      assert [%{target: {:type, ^i}, title: "tApplicant", message: msg}] = found
      assert msg =~ "tApplicant.Income: invalid constraint"
    end

    test "building the list stays fast on a big model (no per-node scan of everything)" do
      m =
        Enum.reduce(1..3000, %Model{}, fn i, m ->
          {m, id} = Model.add_node(m, "decision", i * 10, 0)
          Model.set_text(m, id, 0, "1")
        end)

      ids = m.nodes |> Map.keys() |> Enum.sort()
      # edges set directly: connect/3 checks for cycles, which is not what is being timed here
      m = %{m | edges: ids |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> {a, b, :info} end)}
      results = Eval.run(m)
      {us, found} = :timer.tc(fn -> Problems.list(m, results) end)
      assert found == []
      assert us < 300_000, "took #{div(us, 1000)} ms"
    end

    test "errors come first and the popover text is escaped" do
      {m, id} = Model.add_node(Model.sample(), "decision", 10, 10)
      m = Model.rename(m, id, "<b>x</b>") |> Model.set_text("front", 0, "1 +")
      found = problems(m)
      assert hd(found).severity == :error
      html = Problems.html(found, 100)
      refute html =~ "<b>x</b>"
      assert html =~ "&lt;b&gt;x&lt;/b&gt;"
      assert html =~ ~s|data-click="problem-node:front"|
      assert Problems.html(found, 1) =~ "and #{length(found) - 1} more"
    end
  end

  describe "test scenarios" do
    alias DmnSpike.Dmn

    defp app_value(m), do: m.nodes["app"].expr.result

    test "a new scenario starts as a copy, switching keeps each scenario's own values" do
      m = Model.sample()
      first = app_value(m)
      m = Model.new_scenario(m, "High debt")
      assert Enum.map(Model.scenarios(m), & &1.name) == ["Scenario 1", "High debt"]
      assert m.scenario == 1 and app_value(m) == first, "copied"

      m = Model.set_text(m, "app", 0, "{Income: 1000, Tax: 0, Insurance: 0, Debt: 900}")
      high = app_value(m)
      assert Eval.run(m)["back"].value != Eval.run(Model.sample())["back"].value

      m = Model.switch_scenario(m, 0)
      assert app_value(m) == first, "the first scenario kept its value"
      m = Model.switch_scenario(m, 1)
      assert app_value(m) == high
      assert Model.switch_scenario(m, 9) == m, "an unknown scenario changes nothing"
    end

    test "names are unique and never empty" do
      m = Model.new_scenario(Model.sample(), "Scenario 1")
      assert Enum.map(Model.scenarios(m), & &1.name) == ["Scenario 1", "Scenario 1 2"]
      m = Model.new_scenario(m, "   ")
      assert List.last(Model.scenarios(m)).name == "Scenario 3"
      m = Model.rename_scenario(m, 0, "Base")
      assert hd(Model.scenarios(m)).name == "Base"

      assert Model.rename_scenario(m, 0, "Scenario 1 2") |> Model.scenarios() |> hd() |> Map.get(:name) ==
               "Scenario 1 2 2"

      assert Model.rename_scenario(m, 0, "") |> Model.scenarios() |> hd() |> Map.get(:name) == "Base"
    end

    test "deleting: the last one stays, the previous one becomes active" do
      m = Model.sample()
      assert Model.delete_scenario(m, 0) == m
      m = m |> Model.new_scenario("B") |> Model.set_text("app", 0, "{Income: 1}") |> Model.new_scenario("C")
      assert m.scenario == 2
      m2 = Model.delete_scenario(m, 2)
      assert m2.scenario == 1 and app_value(m2) == "{Income: 1}"
      m3 = Model.delete_scenario(m, 0)
      assert m3.scenario == 1 and Enum.map(Model.scenarios(m3), & &1.name) == ["B", "C"]
    end

    test "scenarios are saved by input name and loaded back by name" do
      m = Model.sample() |> Model.new_scenario("Other") |> Model.set_text("app", 0, "{Income: 5}")
      data = m |> Model.export_scenarios() |> JSON.encode!() |> JSON.decode!()
      assert %{"format" => "popcorn-dmn-scenarios", "scenarios" => [first, %{"name" => "Other"} = other]} = data
      assert other["inputs"]["Applicant Data"] == "{Income: 5}"
      assert Map.keys(first["inputs"]) |> Enum.sort() == ["Applicant Data", "Requested Product"]

      fresh = Model.sample() |> Model.set_text("app", 0, "")
      assert {:ok, loaded, 0} = Model.import_scenarios(fresh, data)
      assert Enum.map(Model.scenarios(loaded), & &1.name) == ["Scenario 1", "Other"]
      assert loaded.scenario == 0 and app_value(loaded) == first["inputs"]["Applicant Data"]
      assert app_value(Model.switch_scenario(loaded, 1)) == "{Income: 5}"
    end

    test "values for inputs that do not exist are counted, and a wrong file is refused" do
      data = %{
        "scenarios" => [
          %{"name" => "S", "inputs" => %{"Applicant Data" => "{Income: 1}", "Gone" => "1", "Also gone" => "2"}}
        ]
      }

      assert {:ok, m, 2} = Model.import_scenarios(Model.sample(), data)
      assert app_value(m) == "{Income: 1}"
      assert {:error, _} = Model.import_scenarios(Model.sample(), %{"scenarios" => []})
      assert {:error, _} = Model.import_scenarios(Model.sample(), %{"scenarios" => [%{"name" => 1, "inputs" => %{}}]})

      assert {:error, _} =
               Model.import_scenarios(Model.sample(), %{"scenarios" => [%{"name" => "x", "inputs" => %{"a" => 1}}]})

      assert {:error, _} = Model.import_scenarios(Model.sample(), %{"other" => 1})
    end

    test "dmn_part is the model without its test data" do
      m = Model.sample()
      assert Model.dmn_part(m) == Model.dmn_part(Model.set_text(m, "app", 0, "{Income: 1}"))
      assert Model.dmn_part(m) == Model.dmn_part(Model.new_scenario(m, "B"))
      assert Model.dmn_part(m) != Model.dmn_part(Model.rename(m, "front", "Other"))
      assert Model.dmn_part(m) != Model.dmn_part(Model.move(m, "front", 1, 1))
    end

    test "test values are not written into the DMN file, and are not an edit to it" do
      m = Model.sample() |> Model.set_text("app", 0, "{Income: 1}")
      refute Dmn.to_xml(m) =~ "{Income: 1}"
      refute Dmn.to_xml(m) =~ "spike:value"
      refute Dmn.to_xml(m) =~ "urn:popcorn-dmn-spike", "the file does not even declare our namespace"

      original = File.read!("test/fixtures/Sample.dmn")
      {:ok, m, _} = Dmn.from_xml(original)
      id = Enum.find_value(m.nodes, fn {k, n} -> if n.type == :input, do: k end)
      out = m |> Model.set_text(id, 0, "{Income: 1}") |> Dmn.to_xml()
      canon = fn xml -> xml |> Saxy.SimpleForm.parse_string() |> elem(1) end
      assert canon.(out) == canon.(original), "changing a test value leaves the file as it was"
    end
  end

  describe "renaming a data type" do
    alias DmnSpike.Dmn

    defp idx(m, name), do: Enum.find_index(m.types, &(&1.name == name))

    test "decision table columns follow a rename, so the export has no undefined type" do
      m = Model.sample()
      renamed = Types.rename_top(m, idx(m, "tRatio"), "tShare")
      assert Enum.all?(renamed.nodes["risk"].expr.inputs, &(&1.type_ref == "tShare"))
      refute Dmn.to_xml(renamed) =~ ~s|"tRatio"|
      refute Dmn.to_xml(renamed) =~ ">tRatio<"
    end

    test "a column alone keeps a type in use" do
      m = Model.sample()
      # no node has tCategory except Risk Category: take that away and only its output column uses it
      m = Model.set_type_ref(m, "risk", nil)
      assert Types.usages(m, "tCategory").nodes == ["Risk Category (output column 1)"]
    end

    test "typing a taken name for a moment does not merge the references of two types" do
      m = Model.sample()
      a = idx(m, "tRatio")
      b = idx(m, "tVerdict")
      verdict_users = for {id, n} <- m.nodes, n.type_ref == "tVerdict", do: id
      ratio_users = for {id, n} <- m.nodes, n.type_ref == "tRatio", do: id

      # tRatio -> tVerdict (taken), then corrected to tShare
      m = Types.rename_top(m, a, "tVerdict")

      assert for({id, n} <- m.nodes, n.type_ref == "tVerdict", do: id) |> Enum.sort() == Enum.sort(verdict_users),
             "nothing was redirected while the name was taken"

      assert Types.find(m, "tRatio"), "references to the old name still find the type"
      assert Types.validate(m, Decimal.new(5), "tRatio") == []
      m = Types.rename_top(m, a, "tShare")
      assert for({id, n} <- m.nodes, n.type_ref == "tShare", do: id) |> Enum.sort() == Enum.sort(ratio_users)
      assert for({id, n} <- m.nodes, n.type_ref == "tVerdict", do: id) |> Enum.sort() == Enum.sort(verdict_users)
      assert Enum.at(m.types, a).name == "tShare" and not Map.has_key?(Enum.at(m.types, a), :committed)
      assert Enum.at(m.types, b).name == "tVerdict"
    end

    test "an empty name is a draft too" do
      m = Model.sample()
      i = idx(m, "tRatio")
      users = for {id, n} <- m.nodes, n.type_ref == "tRatio", do: id
      m = Types.rename_top(m, i, "")
      assert for({id, n} <- m.nodes, n.type_ref == "tRatio", do: id) |> Enum.sort() == Enum.sort(users)
      m = Types.rename_top(m, i, "tShare")
      assert for({id, n} <- m.nodes, n.type_ref == "tShare", do: id) |> Enum.sort() == Enum.sort(users)
    end
  end

  describe "review round five (retained references, built-in names, tables)" do
    alias DmnSpike.Dmn

    @ns5 ~s|xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="d" id="d1"|
    defp import5!(body),
      do: Dmn.from_xml(~s|<definitions #{@ns5}>#{body}</definitions>|) |> then(fn {:ok, m, r} -> {m, r} end)

    @bkm5 """
    <itemDefinition id="t1" name="tAge"><typeRef>number</typeRef></itemDefinition>
    <businessKnowledgeModel id="k" name="K"><variable id="kv" name="K"/>
      <encapsulatedLogic id="el"><formalParameter id="p" name="age" typeRef="tAge"/>
        <literalExpression><text>age</text></literalExpression></encapsulatedLogic>
    </businessKnowledgeModel>
    """

    test "a type only a kept formal parameter uses counts as used, until that node is deleted" do
      {m, _} = import5!(@bkm5)
      assert Types.usages(m, "tAge").nodes == ["K (kept from the file)"]

      # still there after the node is edited: the parameter is written back as it was
      assert Types.usages(Model.rename(m, "k", "K2"), "tAge").nodes == ["K2 (kept from the file)"]
      # a deleted node holds nothing
      assert Types.usages(Model.delete_node(m, "k"), "tAge").nodes == []
    end

    test "references in a read-only expression and in an untouched node count" do
      {m, _} =
        import5!("""
        <itemDefinition id="t1" name="tAge"><typeRef>number</typeRef></itemDefinition>
        <decision id="a" name="A"><variable id="v" name="A"/>
          <relation id="r"><column id="c" name="x" typeRef="tAge"/></relation>
        </decision>
        """)

      assert %{kind: :raw} = m.nodes["a"].expr
      assert Types.usages(m, "tAge").nodes == ["A (kept from the file)"]
    end

    test "a node that already shows its use is not listed twice" do
      m = Model.sample()
      assert Types.usages(m, "tApplicant").nodes == ["Applicant Data"]
    end

    test "a built-in name is a draft too: references do not follow it, and it is reported" do
      m = Model.sample()
      i = Enum.find_index(m.types, &(&1.name == "tRatio"))
      users = for {id, n} <- m.nodes, n.type_ref == "tRatio", do: id
      builtin_users = for {id, n} <- m.nodes, n.type_ref == "number", do: id

      m = Types.rename_top(m, i, "number")
      assert for({id, n} <- m.nodes, n.type_ref == "tRatio", do: id) == users
      assert for({id, n} <- m.nodes, n.type_ref == "number", do: id) == builtin_users
      assert Types.name_error(m.types, [i]) =~ "built-in"
      # the type still resolves by its old name, so its constraint still applies
      assert Types.validate(m, Decimal.new(500), "tRatio") != []

      m = Types.rename_top(m, i, "numberList")
      assert for({id, n} <- m.nodes, n.type_ref == "numberList", do: id) == users
      assert for({id, n} <- m.nodes, n.type_ref == "number", do: id) == builtin_users, "built-in references untouched"
      assert Enum.at(m.types, i).ref == "number", "its own base is still the built-in"
    end

    test "a table with a default output entry is kept read-only instead of returning null when nothing matches" do
      {m, r} =
        import5!("""
        <decision id="a" name="A"><variable id="v" name="A"/>
          <decisionTable hitPolicy="FIRST"><input id="i"><inputExpression><text>1</text></inputExpression></input>
            <output id="o"><defaultOutputEntry><text>"x"</text></defaultOutputEntry></output>
            <rule><inputEntry><text>2</text></inputEntry><outputEntry><text>"y"</text></outputEntry></rule>
          </decisionTable>
        </decision>
        """)

      assert %{kind: :raw, tag: "decisionTable with a default output entry"} = m.nodes["a"].expr
      assert map_size(r.kept) > 0
      assert Dmn.to_xml(m) =~ "<defaultOutputEntry>"
    end

    test "ANY accepts numerically equal outputs written differently, also inside lists and contexts" do
      {m, id} = Model.add_node(Model.sample(), "decision", 0, 0)
      m = Model.set_expr_kind(m, id, :table) |> Model.set_hit_policy(id, "ANY")
      m = Model.set_table_text(m, id, ["h", 0], "1")
      m = Model.set_table_text(m, id, ["e", 0, 0], "1")
      m = Model.add_rule(m, id) |> Model.set_table_text(id, ["e", 1, 0], "1")

      for {a, b} <- [{"1", "1.0"}, {"[1, 2]", "[1.0, 2.00]"}, {"{x: 1}", "{x: 1.0}"}] do
        m2 = m |> Model.set_table_text(id, ["o", 0, 0], a) |> Model.set_table_text(id, ["o", 1, 0], b)
        r = Eval.run(m2)[id]
        assert r.table.message == nil, "#{a} vs #{b}: #{r.table.message}"
        assert r.value != nil
      end

      m3 = m |> Model.set_table_text(id, ["o", 0, 0], "1") |> Model.set_table_text(id, ["o", 1, 0], "2")
      assert Eval.run(m3)[id].table.message =~ "disagree"
    end
  end

  describe "descriptions" do
    alias DmnSpike.Dmn

    test "a description round-trips through a fresh export and is written before the variable" do
      m = Model.set_description(Model.sample(), "front", "Share of income that goes to housing & debt <12%")
      xml = Dmn.to_xml(m)
      assert xml =~ ~r/<description>Share of income that goes to housing &amp; debt &lt;12%<\/description>\s*<variable/
      {:ok, m2, _} = Dmn.from_xml(xml)
      assert m2.nodes["front"].description == "Share of income that goes to housing & debt <12%"
      assert m2.nodes["app"].description == ""
      refute Dmn.to_xml(Model.sample()) =~ "<description"
    end

    test "editing a node keeps its original description element; changing it rewrites only the text" do
      xml = """
      <definitions xmlns="https://www.omg.org/spec/DMN/20240513/MODEL/" name="d" id="d1">
        <decision id="a" name="A">
          <description kie:note="x" xmlns:kie="urn:kie">Keep me</description>
          <variable id="a-v" name="A"/>
          <literalExpression id="a-l"><text>1</text></literalExpression>
        </decision>
      </definitions>
      """

      {:ok, m, _} = Dmn.from_xml(xml)
      assert m.nodes["a"].description == "Keep me"

      out = m |> Model.set_text("a", 0, "2") |> Dmn.to_xml()
      assert out =~ ~s|<description kie:note="x" xmlns:kie="urn:kie">Keep me</description>|

      out = m |> Model.set_description("a", "Changed") |> Dmn.to_xml()
      assert out =~ "<description>Changed</description>"
      refute out =~ "Keep me"
      out = m |> Model.set_description("a", "") |> Dmn.to_xml()
      refute out =~ "<description"
    end

    test "neighbours lists what a node requires and what requires it" do
      {req, by} = Model.neighbours(Model.sample(), "front")
      assert Enum.sort(Enum.map(req, &elem(&1, 0))) == ["app", "prod"]
      assert Enum.sort(Enum.map(by, &elem(&1, 0))) == ["back", "loan", "risk"]
      assert {"back", _, :info} = Enum.find(by, &(elem(&1, 0) == "back"))
    end
  end

  # canonical form of an XML document, for comparing documents (no whitespace-only text, sorted attributes)
  defp parse_xml(xml) do
    canon = fn canon, {tag, attrs, kids} ->
      kids =
        for k <- kids,
            not (is_binary(k) and String.trim(k) == ""),
            do: if(is_binary(k), do: String.trim(k), else: canon.(canon, k))

      {tag, Enum.sort(attrs), kids}
    end

    xml |> Saxy.SimpleForm.parse_string() |> elem(1) |> then(&canon.(canon, &1))
  end

  describe "a file survives being opened and saved" do
    alias DmnSpike.Dmn

    # canonical form: no whitespace-only text, trimmed text, sorted attributes
    defp canon({tag, attrs, kids}) do
      kids =
        for k <- kids,
            not (is_binary(k) and String.trim(k) == ""),
            do: if(is_binary(k), do: String.trim(k), else: canon(k))

      {tag, Enum.sort(attrs), kids}
    end

    defp parse!(xml), do: xml |> Saxy.SimpleForm.parse_string() |> elem(1) |> canon()

    defp elements(xml),
      do:
        Regex.scan(~r/<[A-Za-z][^>\s\/]*/, xml)
        |> Enum.frequencies_by(fn [t] -> t |> String.trim_leading("<") |> String.split(":") |> List.last() end)

    defp import!(file), do: Dmn.from_xml(File.read!(file)) |> then(fn {:ok, m, _} -> m end)
    defp find_all(xml, local), do: Regex.scan(~r/<(?:\w+:)?#{local}\b[^>]*>/, xml) |> Enum.map(&hd/1)

    for file <- ["test/fixtures/Sample.dmn", "test/fixtures/kie_sample.dmn"] do
      test "#{file}: opening and saving without edits gives back the same document" do
        xml = File.read!(unquote(file))
        out = Dmn.to_xml(import!(unquote(file)))
        assert parse!(out) == parse!(xml)
      end
    end

    test "the licence header before the root element is kept" do
      out = Dmn.to_xml(import!("test/fixtures/Sample.dmn"))
      assert out =~ "Licensed to the Apache Software Foundation"
      assert String.starts_with?(out, ~s|<?xml version="1.0" encoding="UTF-8"?>\n<!--|)
    end

    test "moving a node changes only its bounds and its edges' waypoints" do
      m = import!("test/fixtures/Sample.dmn")
      id = Enum.find_value(m.nodes, fn {i, n} -> if n.name == "Front End Ratio", do: i end)
      out = m |> Model.move(id, 900, 40) |> Dmn.to_xml()
      assert elements(out) == elements(File.read!("test/fixtures/Sample.dmn")), "same elements, nothing added or lost"
      assert out =~ ~s|x="900"|
      assert find_all(out, "DMNStyle") |> length() == 11, "the diagram's styles survive"
      assert find_all(out, "DMNLabel") |> length() == 11
      {:ok, m2, _} = Dmn.from_xml(out)
      assert m2.nodes[id].x == 900 and m2.nodes[id].y == 40
    end

    test "renaming keeps ids, extension elements, requirements and prefixes" do
      m = import!("test/fixtures/Sample.dmn")
      id = Enum.find_value(m.nodes, fn {i, n} -> if n.name == "Credit Score Rating", do: i end)
      out = m |> Model.rename(id, "Score Band") |> Dmn.to_xml()
      assert out =~ ~s|<dmn:decision id="#{id}" name="Score Band">|
      assert elements(out) == elements(File.read!("test/fixtures/Sample.dmn"))
      assert out =~ ~r/<dmn:informationRequirement id="_[0-9A-F-]+">/
      refute out =~ "<decision "
    end

    test "editing one expression leaves every other element exactly as it was" do
      m = import!("test/fixtures/Sample.dmn")
      id = Enum.find_value(m.nodes, fn {i, n} -> if n.name == "Back End Ratio", do: i end)
      before = File.read!("test/fixtures/Sample.dmn") |> Saxy.SimpleForm.parse_string() |> elem(1) |> canon()
      out = m |> Model.set_text(id, 0, "(Applicant Data.Monthly.Repayments) + 1") |> Dmn.to_xml()
      {_, _, kids_in} = before
      {_, _, kids_out} = parse!(out)
      differing = for {a, b} <- Enum.zip(kids_in, kids_out), a != b, do: elem(a, 0)
      # Back End Ratio is an invocation in the file; the edit replaces it, so the diagram entries that pointed
      # at the invocation (KIE's column widths) go with it and nothing else changes
      assert differing == ["dmn:decision", "dmndi:DMNDI"]
      assert out =~ "Applicant Data.Monthly.Repayments) + 1"
      ids = Regex.scan(~r/\bid="([^"]+)"/, out) |> Enum.map(&List.last/1) |> MapSet.new()
      refs = Regex.scan(~r/dmnElementRef="([^"]+)"/, out) |> Enum.map(&List.last/1)
      assert Enum.all?(refs, &MapSet.member?(ids, &1)), "no diagram reference points at a removed element"
    end

    test "new elements are written in the file's own prefixes and appear in the diagram" do
      m = import!("test/fixtures/Sample.dmn")
      {m, id} = Model.add_node(m, "decision", 700, 20)
      app = Enum.find_value(m.nodes, fn {i, n} -> if n.name == "Applicant Data", do: i end)
      {:ok, m} = Model.connect(m, app, id)
      out = Dmn.to_xml(m)
      assert out =~ ~s|<dmn:decision id="#{id}" name="New decision">|
      assert out =~ ~s|<dmndi:DMNShape id="dmnshape-drg-#{id}"|
      assert out =~ "<dc:Bounds"
      refute out =~ "<decision ", "no unprefixed DMN elements in a prefixed file"
      {:ok, m2, _} = Dmn.from_xml(out)
      assert m2.nodes[id].name == "New decision" and {app, id, :info} in m2.edges
    end

    test "deleting a node removes its shape and edges and leaves no dangling reference" do
      m = import!("test/fixtures/Sample.dmn")
      id = Enum.find_value(m.nodes, fn {i, n} -> if n.name == "Front End Ratio", do: i end)
      out = m |> Model.delete_node(id) |> Dmn.to_xml()
      refute out =~ ~s|dmnElementRef="#{id}"|
      ids = Regex.scan(~r/\bid="([^"]+)"/, out) |> Enum.map(&List.last/1) |> MapSet.new()
      refs = Regex.scan(~r/dmnElementRef="([^"]+)"/, out) |> Enum.map(&List.last/1)
      assert Enum.all?(refs, &MapSet.member?(ids, &1)), "every dmnElementRef points at an element that exists"
      assert {:ok, _, _} = Dmn.from_xml(out)
    end

    test "types are kept untouched until edited, then regenerated without losing their attributes" do
      m = import!("test/fixtures/Sample.dmn")
      unchanged = Dmn.to_xml(m)
      assert unchanged == Dmn.to_xml(import!("test/fixtures/Sample.dmn"))
      t = Types.find(m, "Requested_Product")
      i = Enum.find_index(m.types, &(&1.name == "Requested_Product"))
      m = %{m | types: List.replace_at(m.types, i, %{t | components: tl(t.components)})}
      out = Dmn.to_xml(m)
      assert out =~ ~s|<dmn:itemDefinition id=|
      assert elements(out)["itemComponent"] == elements(unchanged)["itemComponent"] - 1
    end

    test "an expression the editor cannot edit is kept, shown read-only, and survives edits elsewhere" do
      xml =
        dmn(
          ~s|<decision id="rel" name="Relation"><variable name="Relation"/><relation id="r1"><column name="a"/><row><literalExpression><text>1</text></literalExpression></row></relation></decision><decision id="d2" name="Other"><variable name="Other"/><literalExpression><text>1</text></literalExpression></decision>|
        )

      {:ok, m, r} = Dmn.from_xml(xml)
      assert m.nodes["rel"].expr == %{kind: :raw, tag: "relation"}
      assert r.kept == %{"Relation: relation expression, read-only" => 1}
      assert Eval.run(m)["rel"].value == nil
      assert parse!(Dmn.to_xml(m)) == parse!(xml)
      out = m |> Model.set_text("d2", 0, "2") |> Dmn.to_xml()
      assert out =~ "<relation id=\"r1\">" and out =~ "<column name=\"a\"/>"
      # replacing the kind drops the old expression
      out2 = m |> Model.set_expr_kind("rel", :context) |> Dmn.to_xml()
      refute out2 =~ "<relation"
    end

    test "unknown attributes and elements on an edited element are kept" do
      xml =
        dmn(
          ~s|<decision id="d" name="Old" kie:custom="yes" xmlns:kie="http://www.drools.org/kie/dmn/1.2"><description>why</description><variable id="v" name="Old" typeRef="number"/><literalExpression id="le"><text>1</text></literalExpression></decision>|
        )

      {:ok, m, _} = Dmn.from_xml(xml)
      out = m |> Model.rename("d", "New") |> Dmn.to_xml()
      assert out =~ ~s|kie:custom="yes"|
      assert out =~ "<description>why</description>"
      assert out =~ ~s|<variable id="v" name="New" typeRef="number"/>|
      # DMN's child order is kept: description before variable before the expression
      assert Regex.match?(~r/<description>.*<variable.*<literalExpression/s, out)
    end

    test "a DRG element without an id gets one" do
      {:ok, m, _} = Dmn.from_xml(dmn(~s|<decision name="NoId"><variable name="NoId"/></decision>|))
      [id] = Map.keys(m.nodes)
      assert String.starts_with?(id, "_auto-")
      assert Dmn.to_xml(m) =~ ~s|id="#{id}"|
    end
  end

  describe "types of an imported model (supplied by the page that embeds the editor)" do
    alias DmnSpike.{Dmn, Types}

    @ns "https://www.omg.org/spec/DMN/20230324/MODEL/"

    # what the host sends: a model of item definitions only, with `!` (not null) in the type references
    @imported ~s|<definitions xmlns="#{@ns}" namespace="https://lohn.li/datatypes" id="datatypes" name="Lohn.li">| <>
                ~s|<itemDefinition id="Status" name="Status"><typeRef>string</typeRef><allowedValues><text>"a","b"</text></allowedValues></itemDefinition>| <>
                ~s|<itemDefinition id="Employee" name="Employee">| <>
                ~s|<itemComponent id="Employee.name" name="name" isCollection="false"><typeRef>string!</typeRef></itemComponent>| <>
                ~s|<itemComponent id="Employee.status" name="status" isCollection="false"><typeRef>Status</typeRef></itemComponent>| <>
                ~s|</itemDefinition></definitions>|

    # a DMN 1.5 rule that imports it, as lohn.li stores rules
    @rule ~s|<definitions xmlns="#{@ns}" namespace="n" name="R" id="r">| <>
            ~s|<import id="i" name="lohn" namespace="https://lohn.li/datatypes" locationURI="datatypes.dmn" importType="#{@ns}"/>| <>
            ~s|<inputData id="in" name="e"><variable id="v" name="e" typeRef="lohn.Employee"/></inputData>| <>
            ~s|<decision id="d" name="D"><variable id="dv" name="D" typeRef="string"/>| <>
            ~s|<informationRequirement id="ir"><requiredInput href="#in"/></informationRequirement>| <>
            ~s|<literalExpression id="le"><text>e.name</text></literalExpression></decision></definitions>|

    defp external, do: elem(Dmn.from_xml(@imported), 1).types |> then(&Types.external("lohn", &1))

    test "they are named after the import, and their references follow" do
      ext = external()
      assert Enum.map(ext, & &1.name) == ["lohn.Status", "lohn.Employee"]
      employee = Enum.find(ext, &(&1.name == "lohn.Employee"))
      assert Enum.map(employee.components, &{&1.name, &1.ref}) == [{"name", "string!"}, {"status", "lohn.Status"}]
    end

    test "a type of the import resolves and checks values; an unknown one does not" do
      {:ok, m, _} = Dmn.from_xml(@rule)
      m = %{m | ext_types: external()}

      assert Types.ref_error(m, %{ref: "lohn.Employee"}) == nil
      assert Types.ref_error(m, %{ref: "lohn.Nope"}) =~ "Unknown type"
      assert Types.validate(m, %{"name" => "Ann", "status" => "a"}, "lohn.Employee") == []
      assert [_ | _] = Types.validate(m, %{"name" => "Ann", "status" => "z"}, "lohn.Employee")
      assert DmnSpike.Panel.type_options(m, "lohn.Employee") =~ ~s|value="lohn.Employee" selected|
    end

    test "they are never written to the document, which keeps its import and its DMN 1.5 namespace" do
      {:ok, m, _} = Dmn.from_xml(@rule)
      m = %{m | ext_types: external()}
      out = m |> Model.rename("d", "Pay") |> Dmn.to_xml()

      assert out =~ ~s|<import id="i" name="lohn"|
      assert out =~ ~s|typeRef="lohn.Employee"|
      assert out =~ "DMN/20230324/MODEL"
      refute out =~ "<itemDefinition"
      # they are not part of what is saved, so loading them does not make the document unsaved
      assert Model.dmn_part(m) == Model.dmn_part(%{m | ext_types: []})
    end
  end

  describe "type references: number!, string!, list<string!>!" do
    alias DmnSpike.{Dmn, Panel, Types, TypesPanel}

    defp ui(extra \\ %{}),
      do:
        Map.merge(
          %{sel: nil, closed: MapSet.new(), iopen: MapSet.new(), q: "", insp: false, edit: nil, adv: MapSet.new()},
          extra
        )

    test "they are read as a name or a list, each possibly not null" do
      assert Types.parse_ref("number") == {:ok, {:type, "number", false}}
      assert Types.parse_ref("number!") == {:ok, {:type, "number", true}}
      assert Types.parse_ref("date and time!") == {:ok, {:type, "date and time", true}}
      assert Types.parse_ref("list<string!>!") == {:ok, {:list, {:type, "string", true}, true}}
      assert Types.parse_ref("list<list<number>>") == {:ok, {:list, {:list, {:type, "number", false}, false}, false}}
      assert Types.parse_ref("list<string") == {:ok, {:type, "list<string", false}}
      assert Types.parse_ref("!") == :error
      assert Types.parse_ref("list<>") == :error
      assert Types.ref_names("list<Foo!>!") == ["Foo"]
    end

    test "they resolve against the built-in and the defined types, and say what is unknown" do
      m = Model.sample()

      for ok <- ["number!", "string!", "list<string!>!", "list<tRatio>", "tRatio!", "list<tRatio!>!"],
          do: assert(Types.ref_error(m, %{ref: ok}) == nil, ok)

      assert Types.ref_error(m, %{ref: "list<Nope!>!"}) == ~s|Unknown type "Nope"|
      assert Types.ref_error(m, %{ref: "list<>"}) =~ "Invalid type"
    end

    test "not null rejects null, a list checks its items" do
      m = Model.sample()
      d = &Decimal.new/1

      assert Types.validate(m, nil, "number") == []
      assert Types.validate(m, nil, "number!") == ["must not be null"]
      assert Types.validate(m, d.(1), "number!") == []
      assert Types.validate(m, "x", "number!") == ["expected a number"]

      assert Types.validate(m, ["a", "b"], "list<string!>!") == []
      assert Types.validate(m, ["a", nil], "list<string!>!") == ["must not be null"]
      assert Types.validate(m, ["a", nil], "list<string>") == []
      assert Types.validate(m, nil, "list<string!>!") == ["must not be null"]
      assert Types.validate(m, nil, "list<string>") == []
      assert Types.validate(m, "a", "list<string>") == ["expected a list"]
      assert [_ | _] = Types.validate(m, [d.(1)], "list<string!>!")
      # named types inside a list
      assert Types.validate(m, [d.(5), d.(500)], "list<tRatio>") == ["violates constraint [0..100]"]
      assert Types.validate(m, [d.(5)], "list<tRatio!>!") == []
    end

    test "a component of a data type can have them, and the base type is the item's" do
      t = %{
        name: "tPerson",
        ref: nil,
        collection: false,
        constraint: nil,
        components: [
          %{name: "tags", ref: "list<string!>!", collection: false, constraint: nil, components: []},
          %{name: "age", ref: "number!", collection: false, constraint: nil, components: []}
        ]
      }

      m = %{Model.sample() | types: [t]}

      assert Types.validate(m, %{"tags" => ["a"], "age" => Decimal.new(3)}, "tPerson") == []
      assert Types.validate(m, %{"tags" => ["a"], "age" => nil}, "tPerson") == ["age: must not be null"]
      assert Types.base(m, hd(t.components)) == "string"
      assert Types.base(m, List.last(t.components)) == "number"
    end

    test "they are written to the file and read back as they are" do
      xml =
        ~s|<definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/" namespace="n" id="d" name="R">| <>
          ~s|<itemDefinition id="t" name="tPerson"><itemComponent id="c" name="tags" isCollection="false"><typeRef>list&lt;string!&gt;!</typeRef></itemComponent></itemDefinition>| <>
          ~s|<inputData id="in" name="x"><variable id="v" name="x" typeRef="list&lt;number!&gt;!"/></inputData></definitions>|

      {:ok, m, _} = Dmn.from_xml(xml)
      assert hd(hd(m.types).components).ref == "list<string!>!"
      assert m.nodes["in"].type_ref == "list<number!>!"
      # an edit forces the elements to be written again
      out = m |> Model.rename("in", "y") |> Dmn.to_xml()
      assert {:ok, again, _} = Dmn.from_xml(out)
      assert hd(hd(again.types).components).ref == "list<string!>!"
      assert again.nodes["in"].type_ref == "list<number!>!"
    end

    test "the selects offer them, and keep one that is not among the choices" do
      m = Model.sample()
      html = Panel.type_options(m, "list<tRatio!>!")
      assert html =~ ~s|<optgroup label="Not null">|
      assert html =~ ~s|value="string!"|
      assert html =~ ~s|value="list&lt;string!&gt;!"|
      assert html =~ ~s|value="list&lt;tRatio!&gt;!" selected|
      # a form the choices do not have is kept, not shown as undefined
      assert Panel.type_options(m, "list<list<number>>") =~ ~s|value="list&lt;list&lt;number&gt;&gt;" selected|
    end

    test "a type is used by the nodes that mention it as Foo!, list<Foo>, and renamed with them" do
      m = Model.sample()
      m = Model.set_type_ref(m, "loan", "list<tVerdict!>!")
      assert "Loan Pre-Qualification" in Types.usages(m, "tVerdict").nodes

      renamed = Types.rename_refs(m, "tVerdict", "tOutcome")
      assert renamed.nodes["loan"].type_ref == "list<tOutcome!>!"
      # a reference that does not mention it is not touched
      assert Types.rename_refs(m, "zzz", "yyy").nodes["loan"].type_ref == "list<tVerdict!>!"
    end

    test "imported types are listed read-only in the Data types tab" do
      {:ok, imported, _} =
        Dmn.from_xml(
          ~s|<definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/" namespace="u" id="i" name="T">| <>
            ~s|<itemDefinition id="E" name="Employee"><itemComponent id="E.n" name="first_name" isCollection="false"><typeRef>string!</typeRef></itemComponent>| <>
            ~s|<itemComponent id="E.t" name="tags" isCollection="false"><typeRef>list&lt;string!&gt;!</typeRef></itemComponent></itemDefinition></definitions>|
        )

      m = %{Model.sample() | ext_types: Types.external("lohn", imported.types)}
      html = TypesPanel.tree(m, ui())

      # the row is there, closed, with no selection or edit on it, and it can be opened
      assert html =~ "lohn.Employee"
      assert html =~ ~s|data-click="itoggle:x0"|
      refute html =~ "tsel:x"
      refute html =~ "first_name"

      open = TypesPanel.tree(m, ui(%{iopen: MapSet.new(["x0"])}))
      assert open =~ "first_name"
      assert open =~ "list&lt;string!&gt;!"
      refute open =~ "ttype:x"

      # a search opens what matches
      assert TypesPanel.tree(m, ui(%{q: "first_name"})) =~ "first_name"
      assert TypesPanel.tree(m, ui(%{q: "nothing like this"})) =~ "Nothing matches"
      # a document with no types of its own still shows them
      assert TypesPanel.tree(%{m | types: []}, ui()) =~ "lohn.Employee"
    end
  end
end
