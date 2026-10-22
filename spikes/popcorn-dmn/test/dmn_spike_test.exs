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
      assert Model.required_kinds(:decision) == ["bkm", "decision", "input"]
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
      assert xml =~ ~s|<allowedValues kie:constraintType="range">|
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

      assert {"_app", "_back", :info} in m.edges and {"_back", "_risk", :info} in m.edges and
               {"_dti", "_loan_d", :knowledge} in m.edges

      assert length(m.edges) == 6
      assert r.kept["knowledgeSource"] == 1 and r.kept["textAnnotation"] == 1 and r.kept["association"] == 1
      assert r.kept["authorityRequirement"] == 1
      assert r.dropped == %{}
      assert r.converted == %{"Fee: invocation to a FEEL function call" => 1}
      assert m.nodes["_fee"].expr.result == "feeFunction()"

      assert r.placed == 1 and m.nodes["_fee"].y > m.nodes["_app"].y,
             "the Fee decision has no DMNShape, so it is placed below the rest"
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
      assert differing == ["dmn:decision"], "only the edited decision differs (the diagram is unchanged too)"
      assert out =~ "Applicant Data.Monthly.Repayments) + 1"
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
end
