defmodule DmnSpike.Dmn do
  @moduledoc """
  DMN 1.6 XML import and export for the subset the spike models: item
  definitions, input data, decisions, business knowledge, information and
  knowledge requirements, literal / context / decision-table expressions and
  the DMNDI shapes. Import reports everything it had to drop, so the fidelity
  gap is visible instead of silent. Parsing uses Saxy (pure Elixir).
  """

  alias DmnSpike.{Layout, Model, Svg}

  @ns %{
    "xmlns" => "https://www.omg.org/spec/DMN/20240513/MODEL/",
    "xmlns:dmndi" => "https://www.omg.org/spec/DMN/20230324/DMNDI/",
    "xmlns:dc" => "http://www.omg.org/spec/DMN/20180521/DC/",
    "xmlns:di" => "http://www.omg.org/spec/DMN/20180521/DI/",
    "xmlns:kie" => "http://www.drools.org/kie/dmn/1.2",
    "xmlns:spike" => "urn:popcorn-dmn-spike"
  }

  @elements %{"inputData" => :input, "decision" => :decision, "businessKnowledgeModel" => :bkm}
  @known_top ["itemDefinition", "inputData", "decision", "businessKnowledgeModel", "DMNDI", "extensionElements", "description"]

  # ===================================================================== export

  def to_xml(%Model{} = m, name \\ "Popcorn spike") do
    nodes = m.nodes |> Map.values() |> Enum.sort_by(& &1.id)

    root =
      el("definitions", [{"id", "_definitions"}, {"name", name}, {"namespace", "https://popcorn.spike/dmn"}] ++ Map.to_list(@ns) |> Enum.sort(),
        Enum.map(Enum.with_index(m.types), fn {t, i} -> item_xml(t, "_t#{i}") end) ++
          Enum.map(nodes, &node_xml(m, &1)) ++ [dmndi(m, nodes)]
      )

    ~s|<?xml version="1.0" encoding="UTF-8"?>\n| <> render(root, 0)
  end

  defp item_xml(t, id) do
    attrs = [{"id", id}, {"name", t.name}] ++ if(t.collection, do: [{"isCollection", "true"}], else: [])

    kids =
      if(t.ref, do: [el("typeRef", [], [t.ref])], else: []) ++
        constraint_xml(t.constraint) ++
        Enum.map(Enum.with_index(t.components), fn {c, i} -> item_xml(c, "#{id}-#{i}") |> rename("itemComponent") end)

    el("itemDefinition", attrs, kids)
  end

  defp rename({:el, _, attrs, kids}, tag), do: {:el, tag, attrs, kids}

  defp constraint_xml(nil), do: []
  defp constraint_xml(%{text: ""}), do: []
  defp constraint_xml(%{kind: kind, text: text}), do: [el("typeConstraint", [{"kie:constraintType", to_string(kind)}], [el("text", [], [text])])]

  defp node_xml(m, n) do
    tag = Enum.find_value(@elements, fn {t, k} -> if k == n.type, do: t end)
    var = el("variable", [{"id", "#{n.id}-var"}, {"name", n.name}] ++ if(n.type_ref, do: [{"typeRef", n.type_ref}], else: []), [])
    info = for {from, to, :info} <- m.edges, to == n.id, do: el("informationRequirement", [{"id", req_id(from, to)}], [el(if(m.nodes[from].type == :decision, do: "requiredDecision", else: "requiredInput"), [{"href", "#" <> from}], [])])
    know = for {from, to, :knowledge} <- m.edges, to == n.id, do: el("knowledgeRequirement", [{"id", req_id(from, to)}], [el("requiredKnowledge", [{"href", "#" <> from}], [])])

    body =
      case n.type do
        :input -> input_ext(n)
        :bkm -> [el("encapsulatedLogic", [], Enum.map(Model.params(n), &el("formalParameter", [{"name", &1}], [])) ++ expression_xml(n.expr))]
        :decision -> expression_xml(n.expr)
      end

    el(tag, [{"id", n.id}, {"name", n.name}], [var] ++ info ++ know ++ body)
  end

  defp req_id(from, to), do: "_req-#{from}-#{to}"

  defp input_ext(%{expr: %{result: ""}}), do: []
  defp input_ext(%{expr: %{result: v}}), do: [el("extensionElements", [], [el("spike:value", [], [v])])]

  defp literal(text), do: [el("literalExpression", [], [el("text", [], [text])])]

  defp annotated?(t), do: Map.get(t, :note_title) != nil or Enum.any?(t.rules, &(Map.get(&1, :note, "") != ""))

  defp expression_xml(%{kind: :table} = t) do
    [
      el("decisionTable", [{"hitPolicy", t.hit_policy}],
        Enum.map(t.inputs, fn i -> el("input", [], [el("inputExpression", [], [el("text", [], [i.expr])])]) end) ++
          Enum.map(t.outputs, fn o -> el("output", if(o.name == "", do: [], else: [{"name", o.name}]), []) end) ++
          if(annotated?(t), do: [el("annotation", [{"name", Map.get(t, :note_title) || "Annotation"}], [])], else: []) ++
          Enum.map(t.rules, fn r ->
            el(
              "rule",
              [],
              Enum.map(r.entries, &el("inputEntry", [], [el("text", [], [&1])])) ++
                Enum.map(r.outs, &el("outputEntry", [], [el("text", [], [&1])])) ++
                if(annotated?(t), do: [el("annotationEntry", [], [el("text", [], [Map.get(r, :note, "")])])], else: [])
            )
          end)
      )
    ]
  end

  defp expression_xml(%{rows: [], result: ""}), do: []
  defp expression_xml(%{rows: [], result: text}), do: literal(text)

  defp expression_xml(%{rows: rows, result: result}) do
    entries =
      Enum.map(rows, fn r -> el("contextEntry", [], [el("variable", [{"name", r.name}], []) | literal(r.text)]) end) ++
        [el("contextEntry", [], literal(result))]

    [el("context", [], entries)]
  end

  defp dmndi(m, nodes) do
    shapes =
      for n <- nodes do
        el("dmndi:DMNShape", [{"id", "#{n.id}-shape"}, {"dmnElementRef", n.id}], [
          el("dc:Bounds", [{"x", n.x}, {"y", n.y}, {"width", n.w}, {"height", n.h}], [])
        ])
      end

    edges =
      for {from, to, _} <- m.edges do
        {x1, y1, x2, y2} = Svg.endpoints(m.nodes[from], m.nodes[to])

        el("dmndi:DMNEdge", [{"id", "#{req_id(from, to)}-edge"}, {"dmnElementRef", req_id(from, to)}], [
          el("di:waypoint", [{"x", x1}, {"y", y1}], []),
          el("di:waypoint", [{"x", x2}, {"y", y2}], [])
        ])
      end

    el("dmndi:DMNDI", [], [el("dmndi:DMNDiagram", [{"id", "_diagram"}], shapes ++ edges)])
  end

  # tiny indenting XML writer ------------------------------------------------------

  defp el(tag, attrs, kids), do: {:el, tag, attrs, kids}

  defp render({:el, tag, attrs, kids}, depth) do
    pad = String.duplicate("  ", depth)
    open = pad <> "<" <> tag <> Enum.map_join(attrs, "", fn {k, v} -> ~s| #{k}="#{esc_attr(to_string(v))}"| end)

    cond do
      kids == [] -> open <> "/>\n"
      Enum.all?(kids, &is_binary/1) -> open <> ">" <> Enum.map_join(kids, "", &esc/1) <> "</" <> tag <> ">\n"
      true -> open <> ">\n" <> Enum.map_join(kids, "", &render(&1, depth + 1)) <> pad <> "</" <> tag <> ">\n"
    end
  end

  defp esc(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  defp esc_attr(s), do: s |> esc() |> String.replace("\"", "&quot;")

  # ===================================================================== import

  @doc "Returns `{:ok, model, report}` or `{:error, message}`."
  def from_xml(xml) when is_binary(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, {root, attrs, children}} ->
        with true <- local(root) == "definitions" || {:error, "not a DMN file: root element is <#{local(root)}>"},
             :ok <- check_ids(children) do
          {model, report} = build(attrs, children)
          {:ok, model, report}
        end

      {:error, e} ->
        {:error, "XML parse error: " <> Exception.message(e)}
    end
  end

  # Element ids end up in HTML attributes and CSS selectors. DMN ids are XML names, so anything
  # else (quotes, angle brackets, spaces) is refused here, at the only place they enter.
  defp check_ids(children) do
    bad =
      for {tag, a, _} <- children, @elements[local(tag)], id = attr(a, "id"), not Regex.match?(~r/\A[\w.\-]+\z/u, id), do: id

    case bad do
      [] -> :ok
      [id | _] -> {:error, "invalid element id #{inspect(String.slice(id, 0, 40))}: ids may only contain letters, digits, _, . and -"}
    end
  end

  defp build(attrs, children) do
    children = Enum.filter(children, &is_tuple/1)
    dropped = children |> Enum.map(&local(elem(&1, 0))) |> Enum.reject(&(&1 in @known_top)) |> Enum.frequencies()

    types = for {tag, _, _} = e <- children, local(tag) == "itemDefinition", do: item(e)
    {nodes, notes} = for({tag, _, _} = e <- children, @elements[local(tag)], do: read_node(e)) |> Enum.unzip()
    nodes = Map.new(nodes, &{&1.id, &1})
    reqs = requirements(children, nodes)
    {shapes, extra_diagrams} = shapes(children)

    {nodes, missing} =
      Enum.reduce(nodes, {%{}, []}, fn {id, n}, {acc, miss} ->
        case shapes[id] do
          nil -> {Map.put(acc, id, n), [id | miss]}
          {x, y, w, h} -> {Map.put(acc, id, %{n | x: x, y: y, w: w, h: h}), miss}
        end
      end)

    valid = Enum.filter(reqs.edges, fn {f, t, _} -> nodes[f] && nodes[t] end)

    model = %Model{nodes: nodes, edges: valid, types: types, next: next_id(nodes)}
    model = place_missing(model, Enum.sort(missing))

    all_notes = Enum.flat_map(notes, & &1)

    report = %{
      name: attr(attrs, "name"),
      nodes: map_size(nodes),
      edges: length(valid),
      types: length(types),
      placed: length(missing),
      converted: merge_counts(%{}, for(n <- all_notes, String.contains?(n, ": converted: "), do: String.replace(n, ": converted: ", ": "))),
      dropped:
        Map.merge(dropped, reqs.dropped, fn _, a, b -> a + b end)
        |> merge_counts(for n <- all_notes, not String.contains?(n, ": converted: "), do: n)
        |> merge_counts(if(extra_diagrams > 0, do: ["extra DMNDiagram"], else: []))
        |> merge_counts(for {f, t, _} <- reqs.edges, !(nodes[f] && nodes[t]), do: "requirement to unknown element")
    }

    {model, report}
  end

  # keep file positions; with no diagram at all lay everything out, otherwise put the
  # shapeless elements in a row below the rest
  defp place_missing(model, []), do: model
  defp place_missing(%Model{nodes: nodes} = model, missing) when length(missing) == map_size(nodes), do: Layout.run(model)

  defp place_missing(%Model{nodes: nodes} = model, missing) do
    y = nodes |> Map.values() |> Enum.map(&(&1.y + &1.h)) |> Enum.max() |> Kernel.+(60)

    {nodes, _} =
      Enum.reduce(missing, {nodes, 40}, fn id, {acc, x} ->
        n = acc[id]
        {Map.put(acc, id, %{n | x: x, y: y}), x + n.w + 40}
      end)

    %{model | nodes: nodes}
  end

  defp merge_counts(map, items), do: Enum.reduce(items, map, fn k, acc -> Map.update(acc, k, 1, &(&1 + 1)) end)

  defp next_id(nodes), do: Enum.find(1..10_000, fn i -> not Map.has_key?(nodes, "n#{i}") end)

  # item definitions ---------------------------------------------------------------

  defp item({_, attrs, kids}) do
    kids = Enum.filter(kids, &is_tuple/1)
    ref = kids |> find("typeRef") |> text()
    comps = for {tag, _, _} = c <- kids, local(tag) == "itemComponent", do: item(c)
    tc = find(kids, "typeConstraint") || find(kids, "allowedValues")

    constraint =
      case tc && text(find(children(tc), "text")) do
        nil -> nil
        "" -> nil
        t -> %{kind: constraint_kind(attrs_of(tc), t), text: String.trim(t)}
      end

    %{
      name: attr(attrs, "name") || "unnamed",
      ref: if(comps == [] and ref not in [nil, ""], do: String.trim(ref), else: nil),
      collection: attr(attrs, "isCollection") == "true",
      constraint: constraint,
      components: comps
    }
  end

  defp attrs_of({_, a, _}), do: a

  defp constraint_kind(attrs, text) do
    case Enum.find_value(attrs, fn {k, v} -> if local(k) == "constraintType", do: v end) do
      kind when kind in ["enumeration", "range", "expression"] -> String.to_existing_atom(kind)
      _ -> infer_kind(text)
    end
  end

  defp infer_kind(text) do
    cond do
      Regex.match?(~r/^\s*[\[\(\]].*\.\..*[\]\)\[]\s*$/s, text) or Regex.match?(~r/^\s*(<=|>=|<|>)/, text) -> :range
      String.contains?(text, ",") or Regex.match?(~r/^\s*("[^"]*"|\d+(\.\d+)?)\s*$/, text) -> :enumeration
      true -> :expression
    end
  end

  # nodes ----------------------------------------------------------------------------

  defp read_node({tag, attrs, kids}) do
    kids = Enum.filter(kids, &is_tuple/1)
    type = @elements[local(tag)]
    id = attr(attrs, "id") || "n-#{:erlang.unique_integer([:positive])}"
    var = find(kids, "variable")
    {expr, expr_notes} = expression(type, kids)
    name = attr(attrs, "name") || id

    n = %{
      id: id, type: type, name: name, x: 0, y: 0, w: 150, h: 60, expr: expr,
      type_ref: var && attr(attrs_of(var), "typeRef")
    }

    {n, Enum.map(expr_notes, &"#{name}: #{&1}")}
  end

  defp expression(:input, kids) do
    ext = find(kids, "extensionElements")
    value = ext && ext |> children() |> find("value") |> text()
    {%{rows: [], result: value || ""}, []}
  end

  defp expression(:bkm, kids) do
    case find(kids, "encapsulatedLogic") do
      nil ->
        {%{rows: [], result: "", params: []}, []}

      {_, _, lk} = logic ->
        params = for {t, a, _} <- Enum.filter(lk, &is_tuple/1), local(t) == "formalParameter", do: attr(a, "name")

        {body, notes} =
          case expression(:decision, children(logic)) do
            {%{kind: :table}, notes} -> {%{rows: [], result: ""}, ["decision table in a business knowledge model" | notes]}
            other -> other
          end

        {Map.put(body, :params, params), notes}
    end
  end

  defp expression(:decision, kids) do
    case first_expression(kids) do
      nil -> {%{rows: [], result: ""}, []}
      {:literal, t} -> {%{rows: [], result: t}, []}
      {:converted, t, note} -> {%{rows: [], result: t}, [note]}
      {:context, entries, notes} -> context_expr(entries, notes)
      {:table, t, notes} -> {t, notes}
      {:other, tag} -> {%{rows: [], result: ""}, ["unsupported expression <#{tag}>"]}
    end
  end

  @expr_tags ["literalExpression", "context", "decisionTable", "invocation", "relation", "functionDefinition", "list", "conditional", "filter", "for", "some", "every", "decisionTable"]

  defp first_expression(kids) do
    case Enum.find(kids, fn
           {t, _, _} -> local(t) in @expr_tags
           _ -> false
         end) do
      {t, _, k} = e ->
        case local(t) do
          "literalExpression" -> {:literal, text(find(k, "text"))}
          "invocation" -> invocation(e)
          "context" -> {:context, Enum.filter(k, &(is_tuple(&1) and local(elem(&1, 0)) == "contextEntry")), []}
          "decisionTable" -> table(e)
          other -> {:other, other}
        end

      nil ->
        nil
    end
  end

  # <invocation> = a call of a business knowledge model: becomes the FEEL call `name(param: expr, ...)`
  defp invocation({_, _, k}) do
    k = Enum.filter(k, &is_tuple/1)
    callee = k |> find("literalExpression") |> children() |> find("text") |> text()

    bindings =
      for {t, _, bk} <- k, local(t) == "binding" do
        bk = Enum.filter(bk, &is_tuple/1)
        param = bk |> find("parameter") |> then(&(&1 && attr(attrs_of(&1), "name")))

        expr =
          case first_expression(bk) do
            nil -> "null"
            {:literal, t} -> t
            {:converted, t, _} -> t
            _ -> nil
          end

        {param, expr}
      end

    if callee in [nil, ""] or Enum.any?(bindings, fn {p, e} -> p == nil or e == nil end) do
      {:other, "invocation"}
    else
      args = Enum.map_join(bindings, ", ", fn {p, e} -> "#{p}: #{e}" end)
      {:converted, "#{callee}(#{args})", "converted: invocation to a FEEL function call"}
    end
  end

  defp context_expr(entries, notes) do
    parsed =
      for {_, _, k} <- entries do
        k = Enum.filter(k, &is_tuple/1)
        var = find(k, "variable")
        value = case first_expression(k) do
          {:literal, t} -> {t, []}
          {:converted, t, note} -> {t, [note]}
          nil -> {"", []}
          {:other, tag} -> {"", ["unsupported context entry expression <#{tag}>"]}
          _ -> {"", ["nested expression in context entry"]}
        end

        {var && attr(attrs_of(var), "name"), elem(value, 0), elem(value, 1)}
      end

    {named, unnamed} = Enum.split_with(parsed, fn {name, _, _} -> name != nil end)
    result = case unnamed do [{_, t, _} | _] -> t; [] -> "" end
    extra = Enum.flat_map(parsed, &elem(&1, 2))
    {%{rows: Enum.map(named, fn {n, t, _} -> %{name: n, text: t} end), result: result}, notes ++ extra}
  end

  defp table({_, attrs, kids}) do
    kids = Enum.filter(kids, &is_tuple/1)
    inputs = for {t, _, k} <- kids, local(t) == "input", do: %{expr: k |> find("inputExpression") |> children() |> find("text") |> text() |> Kernel.||("")}
    outputs = for {t, a, _} <- kids, local(t) == "output", do: %{name: attr(a, "name") || ""}
    outputs = if outputs == [], do: [%{name: ""}], else: outputs
    n_out = length(outputs)

    rules =
      for {t, _, k} <- kids, local(t) == "rule" do
        k = Enum.filter(k, &is_tuple/1)
        entries = for {t2, _, ek} <- k, local(t2) == "inputEntry", do: text(find(ek, "text")) || ""
        outs = for {t2, _, ek} <- k, local(t2) == "outputEntry", do: out_text(ek)
        note = for {t2, _, ek} <- k, local(t2) == "annotationEntry", do: text(find(ek, "text")) || ""
        %{entries: entries, outs: Enum.take(outs ++ List.duplicate("", n_out), n_out), note: List.first(note) || ""}
      end

    annotations = for {t, a, _} <- kids, local(t) == "annotation", do: attr(a, "name") || "Annotation"

    notes =
      (if length(annotations) > 1, do: ["#{length(annotations) - 1} further annotation columns ignored"], else: []) ++
        (if attr(attrs, "aggregation"), do: ["aggregation #{attr(attrs, "aggregation")} ignored"], else: [])

    {:table,
     %{
       kind: :table,
       hit_policy: attr(attrs, "hitPolicy") || "UNIQUE",
       inputs: inputs,
       outputs: outputs,
       note_title: List.first(annotations),
       rules: rules
     }, notes}
  end

  defp out_text(kids) do
    kids = Enum.filter(kids, &is_tuple/1)

    case find(kids, "text") do
      nil -> (find(kids, "literalExpression") |> children() |> find("text") |> text()) || ""
      t -> text(t) || ""
    end
  end

  # requirements ---------------------------------------------------------------------

  defp requirements(children, nodes) do
    Enum.reduce(children, %{edges: [], dropped: %{}}, fn {tag, attrs, kids}, acc ->
      if @elements[local(tag)] do
        to = attr(attrs, "id")

        Enum.reduce(Enum.filter(kids, &is_tuple/1), acc, fn {t, _, k}, acc ->
          case local(t) do
            "informationRequirement" -> add_req(acc, k, ["requiredDecision", "requiredInput"], to, :info, nodes)
            "knowledgeRequirement" -> add_req(acc, k, ["requiredKnowledge"], to, :knowledge, nodes)
            "authorityRequirement" -> update_in(acc.dropped, &Map.update(&1, "authorityRequirement", 1, fn n -> n + 1 end))
            _ -> acc
          end
        end)
      else
        acc
      end
    end)
  end

  defp add_req(acc, kids, tags, to, kind, _nodes) do
    ref = for {t, a, _} <- Enum.filter(kids, &is_tuple/1), local(t) in tags, do: attr(a, "href")

    Enum.reduce(ref, acc, fn href, acc ->
      from = href |> to_string() |> String.split("#") |> List.last()
      update_in(acc.edges, &(&1 ++ [{from, to, kind}]))
    end)
  end

  # DMNDI ------------------------------------------------------------------------------

  defp shapes(children) do
    diagrams =
      for {t, _, k} <- children, local(t) == "DMNDI", {t2, _, _} = d <- Enum.filter(k, &is_tuple/1), local(t2) == "DMNDiagram", do: d

    case diagrams do
      [] ->
        {%{}, 0}

      [{_, _, k} | rest] ->
        shapes =
          for {t, a, sk} <- Enum.filter(k, &is_tuple/1),
              local(t) == "DMNShape",
              {tb, ba, _} <- Enum.filter(sk, &is_tuple/1),
              local(tb) == "Bounds",
              into: %{} do
            {attr(a, "dmnElementRef"), {num(ba, "x"), num(ba, "y"), num(ba, "width", 150), num(ba, "height", 60)}}
          end

        {shapes, length(rest)}
    end
  end

  defp num(attrs, key, default \\ 0) do
    case attr(attrs, key) && Float.parse(attr(attrs, key)) do
      {f, _} -> round(f)
      _ -> default
    end
  end

  # simple-form helpers -------------------------------------------------------------------

  defp local(name), do: name |> String.split(":") |> List.last()
  defp attr(attrs, name), do: Enum.find_value(attrs, fn {k, v} -> if k == name or local(k) == name, do: v end)
  defp children({_, _, kids}), do: Enum.filter(kids, &is_tuple/1)
  defp children(nil), do: []
  defp find(kids, name), do: Enum.find(kids, fn t -> is_tuple(t) and local(elem(t, 0)) == name end)

  defp text(nil), do: nil
  defp text({_, _, kids}), do: kids |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim()
end
