defmodule DmnSpikeTest do
  use ExUnit.Case

  alias DmnSpike.{Autocomplete, Eval, Highlight, Model, Svg}

  test "svg renders every node and edge, with arrow markers" do
    m = Model.sample()
    svg = Svg.scene(m, %{}, nil)
    assert length(String.split(svg, "<line")) - 1 == length(m.edges)
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
end
