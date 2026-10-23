defmodule DmnSpike.Dmn do
  @moduledoc """
  DMN 1.6 XML import and export for the subset the spike models: item
  definitions, input data, decisions, business knowledge, information and
  knowledge requirements, literal / context / decision-table expressions and
  the DMNDI shapes. Import reports everything it had to drop, so the fidelity
  gap is visible instead of silent. Parsing uses Saxy (pure Elixir).
  """

  alias DmnSpike.{Layout, Model, Svg}
  alias DmnSpike.Dmn.Overlay

  @ns %{
    "xmlns" => "https://www.omg.org/spec/DMN/20240513/MODEL/",
    "xmlns:dmndi" => "https://www.omg.org/spec/DMN/20230324/DMNDI/",
    "xmlns:dc" => "http://www.omg.org/spec/DMN/20180521/DC/",
    "xmlns:di" => "http://www.omg.org/spec/DMN/20180521/DI/",
    "xmlns:kie" => "http://www.drools.org/kie/dmn/1.2"
  }

  @doc false
  def ns_uri(prefix), do: @ns["xmlns:" <> prefix]

  @elements %{
    "inputData" => :input,
    "decision" => :decision,
    "businessKnowledgeModel" => :bkm,
    "textAnnotation" => :annotation,
    "knowledgeSource" => :source,
    "group" => :group
  }
  @known_top [
    "itemDefinition",
    "inputData",
    "decision",
    "businessKnowledgeModel",
    "DMNDI",
    "extensionElements",
    "description",
    "textAnnotation",
    "knowledgeSource",
    "group",
    "association"
  ]

  # ===================================================================== export

  def to_xml(m, name \\ "Popcorn spike") do
    {header, root} = document(m, name)
    header <> render(root, 0)
  end

  @doc """
  The document as `{header, root element}`: the text before the root (declaration, comments) and the tree that
  `render/2` writes. A model that came from a file is written back into that file's document.
  """
  def document(m, name \\ "Popcorn spike")
  def document(%Model{doc: doc} = m, _name) when doc != nil, do: Overlay.document(m)

  def document(%Model{} = m, name) do
    # DRG elements first, then annotations and groups, as the schema has it
    nodes = m.nodes |> Map.values() |> Enum.sort_by(&{&1.type in [:annotation, :group], &1.id})

    root =
      el(
        "definitions",
        ([{"id", "_definitions"}, {"name", name}, {"namespace", "https://popcorn.spike/dmn"}] ++ Map.to_list(@ns))
        |> Enum.sort(),
        Enum.map(Enum.with_index(m.types), fn {t, i} -> item_xml(t, "_t#{i}") end) ++
          Enum.map(nodes, &node_xml(m, &1)) ++
          Enum.map(for({_, _, :association} = l <- m.links, do: l), &link_xml/1) ++ [dmndi(m, nodes)]
      )

    {~s|<?xml version="1.0" encoding="UTF-8"?>\n|, root}
  end

  @doc false
  def item_xml(t, id) do
    attrs = [{"id", id}, {"name", t.name}] ++ if(t.collection, do: [{"isCollection", "true"}], else: [])

    # DMN allows either a typeRef or components, never both: components left over from when this was a
    # structure would turn it back into one on the next import
    components =
      if t.ref,
        do: [],
        else:
          Enum.map(Enum.with_index(t.components), fn {c, i} -> item_xml(c, "#{id}-#{i}") |> rename("itemComponent") end)

    kids =
      if(t.ref, do: [el("typeRef", [], [t.ref])], else: []) ++ constraint_xml(t.constraint, t.collection) ++ components

    el("itemDefinition", attrs, kids)
  end

  defp rename({:el, _, attrs, kids}, tag), do: {:el, tag, attrs, kids}

  # as the KIE editor does: allowedValues for a plain type, typeConstraint for a list
  defp constraint_xml(nil, _), do: []
  defp constraint_xml(%{text: ""}, _), do: []

  defp constraint_xml(%{kind: kind, text: text}, collection?),
    do: [
      el(if(collection?, do: "typeConstraint", else: "allowedValues"), [{"kie:constraintType", to_string(kind)}], [
        el("text", [], [text])
      ])
    ]

  defp description_xml(n), do: if(Model.description(n) == "", do: [], else: [el("description", [], [n.description])])

  @doc false
  def node_xml(_m, %{type: :annotation} = n),
    do: el("textAnnotation", [{"id", n.id}], description_xml(n) ++ [el("text", [], [n.name])])

  def node_xml(_m, %{type: :group} = n), do: el("group", [{"id", n.id}, {"name", n.name}], description_xml(n))

  def node_xml(m, %{type: :source} = n),
    do: el("knowledgeSource", [{"id", n.id}, {"name", n.name}], description_xml(n) ++ authority_xml(m, n))

  def node_xml(m, n) do
    tag = Enum.find_value(@elements, fn {t, k} -> if k == n.type, do: t end)

    var =
      el(
        "variable",
        [{"id", "#{n.id}-var"}, {"name", n.name}] ++ if(n.type_ref, do: [{"typeRef", n.type_ref}], else: []),
        []
      )

    info = for {from, to, :info} <- m.edges, to == n.id, do: req_xml(m, from, to, :info)
    know = for {from, to, :knowledge} <- m.edges, to == n.id, do: req_xml(m, from, to, :knowledge)

    body =
      case n.type do
        # the test values of an input are scenarios, kept outside the file
        :input ->
          []

        :bkm ->
          [
            el(
              "encapsulatedLogic",
              [],
              Enum.map(Model.params(n), &el("formalParameter", [{"name", &1}], [])) ++ expression_xml(n.expr)
            )
          ]

        :decision ->
          expression_xml(n.expr)
      end

    desc = description_xml(n)
    reqs = info ++ know ++ authority_xml(m, n)
    # a business knowledge model's logic comes before its requirements; a decision's expression after them
    tail = if n.type == :bkm, do: body ++ reqs, else: reqs ++ body
    el(tag, [{"id", n.id}, {"name", n.name}], desc ++ [var] ++ tail)
  end

  @doc false
  def req_xml(m, from, to, :info),
    do:
      el("informationRequirement", [{"id", req_id(from, to)}], [
        el(
          if(m.nodes[from].type == :decision, do: "requiredDecision", else: "requiredInput"),
          [{"href", "#" <> from}],
          []
        )
      ])

  def req_xml(_m, from, to, :knowledge),
    do: el("knowledgeRequirement", [{"id", req_id(from, to)}], [el("requiredKnowledge", [{"href", "#" <> from}], [])])

  def req_xml(m, from, to, :authority) do
    required =
      case m.nodes[from].type do
        :input -> "requiredInput"
        :decision -> "requiredDecision"
        _ -> "requiredAuthority"
      end

    el("authorityRequirement", [{"id", req_id(from, to)}], [el(required, [{"href", "#" <> from}], [])])
  end

  defp authority_xml(m, n), do: for({from, to, :authority} <- m.links, to == n.id, do: req_xml(m, from, to, :authority))

  @doc false
  def req_id(from, to), do: "_req-#{from}-#{to}"

  @doc "The element that carries a link: an association is a top-level element of its own."
  def link_xml({from, to, :association}) do
    el("association", [{"id", link_id(from, to)}], [
      el("sourceRef", [{"href", "#" <> from}], []),
      el("targetRef", [{"href", "#" <> to}], [])
    ])
  end

  @doc false
  def link_id(from, to), do: "_assoc-#{from}-#{to}"

  @doc "The id of the diagram element an edge refers to."
  def edge_id(from, to, :association), do: link_id(from, to)
  def edge_id(from, to, _kind), do: req_id(from, to)

  defp literal(text), do: [el("literalExpression", [], [el("text", [], [text])])]

  defp type_attr(col) do
    case Map.get(col, :type_ref) do
      ref when ref in [nil, ""] -> []
      ref -> [{"typeRef", ref}]
    end
  end

  defp annotated?(t), do: Map.get(t, :note_title) != nil or Enum.any?(t.rules, &(Map.get(&1, :note, "") != ""))

  @doc false
  def expression_xml(%{kind: :table} = t) do
    [
      el(
        "decisionTable",
        [{"hitPolicy", t.hit_policy}],
        Enum.map(t.inputs, fn i ->
          el("input", [], [el("inputExpression", type_attr(i), [el("text", [], [i.expr])])])
        end) ++
          Enum.map(t.outputs, fn o ->
            el("output", if(o.name == "", do: [], else: [{"name", o.name}]) ++ type_attr(o), [])
          end) ++
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

  def expression_xml(%{kind: :raw}), do: []
  def expression_xml(%{rows: [], result: ""}), do: []
  def expression_xml(%{rows: [], result: text}), do: literal(text)

  def expression_xml(%{rows: rows, result: result}) do
    # no result entry: the context's value is the context itself (see Eval)
    final = if result == "", do: [], else: [el("contextEntry", [], literal(result))]

    entries =
      Enum.map(rows, fn r -> el("contextEntry", [], [el("variable", [{"name", r.name}], []) | literal(r.text)]) end) ++
        final

    [el("context", [], entries)]
  end

  @doc false
  def dmndi(m, nodes) do
    shapes =
      for n <- nodes do
        el("dmndi:DMNShape", [{"id", "#{n.id}-shape"}, {"dmnElementRef", n.id}], [
          el("dc:Bounds", [{"x", n.x}, {"y", n.y}, {"width", n.w}, {"height", n.h}], [])
        ])
      end

    edges =
      for {from, to, kind} <- Model.edges_all(m) do
        {x1, y1, x2, y2} = Svg.endpoints(m, from, to)
        rid = edge_id(from, to, kind)

        el("dmndi:DMNEdge", [{"id", "#{rid}-edge"}, {"dmnElementRef", rid}], [
          el("di:waypoint", [{"x", x1}, {"y", y1}], []),
          el("di:waypoint", [{"x", x2}, {"y", y2}], [])
        ])
      end

    el("dmndi:DMNDI", [], [el("dmndi:DMNDiagram", [{"id", "_diagram"}], shapes ++ edges)])
  end

  # tiny indenting XML writer ------------------------------------------------------

  @doc false
  def el(tag, attrs, kids), do: {:el, tag, attrs, kids}

  @doc false
  def render({:el, tag, attrs, kids}, depth) do
    pad = String.duplicate("  ", depth)
    open = pad <> "<" <> tag <> Enum.map_join(attrs, "", fn {k, v} -> ~s| #{k}="#{esc_attr(to_string(v))}"| end)

    cond do
      kids == [] -> open <> "/>\n"
      Enum.all?(kids, &is_binary/1) -> open <> ">" <> Enum.map_join(kids, "", &esc/1) <> "</" <> tag <> ">\n"
      # text mixed with elements: written as it was, without indentation that would add text
      Enum.any?(kids, &is_binary/1) -> open <> ">" <> inline(kids) <> "</" <> tag <> ">\n"
      true -> open <> ">\n" <> Enum.map_join(kids, "", &render(&1, depth + 1)) <> pad <> "</" <> tag <> ">\n"
    end
  end

  defp inline(kids) do
    Enum.map_join(kids, "", fn
      text when is_binary(text) ->
        esc(text)

      {:el, tag, attrs, kids} ->
        open = "<" <> tag <> Enum.map_join(attrs, "", fn {k, v} -> ~s| #{k}="#{esc_attr(to_string(v))}"| end)
        if kids == [], do: open <> "/>", else: open <> ">" <> inline(kids) <> "</" <> tag <> ">"
    end)
  end

  @doc """
  The same text as `render/2` as a list of lines, plus where each element is: `{from, to, element, parent}` with
  1-based inclusive line numbers (`first` is the number of the first line) and `parent` as `{from, element}` or nil.
  Used by `DmnSpike.XmlIndex`; a test keeps the two writers identical.
  """
  def render_lines(root, depth \\ 0, first \\ 1) do
    {rev, spans, n} = lines_of(root, depth, nil, {[], [], first - 1})
    {Enum.reverse(rev), Enum.reverse(spans), n - first + 1}
  end

  defp lines_of({:el, tag, attrs, kids} = el, depth, parent, {lines, spans, n0}) do
    pad = String.duplicate("  ", depth)
    open = pad <> "<" <> tag <> Enum.map_join(attrs, "", fn {k, v} -> ~s| #{k}="#{esc_attr(to_string(v))}"| end)

    {lines, spans, n} =
      cond do
        kids == [] ->
          push(open <> "/>", {lines, spans, n0})

        Enum.all?(kids, &is_binary/1) ->
          push(open <> ">" <> Enum.map_join(kids, "", &esc/1) <> "</" <> tag <> ">", {lines, spans, n0})

        # text mixed with elements: one line, as `render/2` writes it
        Enum.any?(kids, &is_binary/1) ->
          push(open <> ">" <> inline(kids) <> "</" <> tag <> ">", {lines, spans, n0})

        true ->
          acc = push(open <> ">", {lines, spans, n0})
          acc = Enum.reduce(kids, acc, &lines_of(&1, depth + 1, {n0 + 1, el}, &2))
          push(pad <> "</" <> tag <> ">", acc)
      end

    {lines, [{n0 + 1, n, el, parent} | spans], n}
  end

  # a text that contains a newline is several lines in the document
  defp push(text, {lines, spans, n}) do
    parts = String.split(text, "\n")
    {Enum.reverse(parts) ++ lines, spans, n + length(parts)}
  end

  defp esc(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
  defp esc_attr(s), do: s |> esc() |> String.replace("\"", "&quot;")

  # ===================================================================== import

  @doc "Returns `{:ok, model, report}` or `{:error, message}`."
  def from_xml(xml) when is_binary(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, {root, attrs, children}} ->
        children = ensure_ids(children)

        with true <- local(root) == "definitions" || {:error, "not a DMN file: root element is <#{local(root)}>"},
             :ok <- check_ids(children) do
          {model, report} = build(attrs, children)
          {shapes, _} = shapes(children)
          doc = Overlay.build(xml, root, attrs, Enum.filter(children, &is_tuple/1), model, shapes)
          {:ok, %{model | doc: doc}, report}
        end

      {:error, e} ->
        {:error, "XML parse error: " <> Exception.message(e)}
    end
  end

  # DRG elements, associations and requirements without an id get one, so every element can be found
  # again when the file is written back, and a diagram edge can refer to it
  @requirements ["informationRequirement", "knowledgeRequirement", "authorityRequirement"]

  defp ensure_ids(children) do
    children
    |> Enum.with_index()
    |> Enum.map(fn
      {{tag, a, k}, i} ->
        a =
          if (@elements[local(tag)] || local(tag) == "association") && attr(a, "id") == nil,
            do: a ++ [{"id", "_auto-#{i}"}],
            else: a

        k = if @elements[local(tag)], do: ensure_requirement_ids(k, i), else: k
        {tag, a, k}

      {other, _} ->
        other
    end)
  end

  defp ensure_requirement_ids(kids, i) do
    kids
    |> Enum.with_index()
    |> Enum.map(fn
      {{t, a, k}, j} ->
        if local(t) in @requirements and attr(a, "id") == nil,
          do: {t, a ++ [{"id", "_auto-#{i}-#{j}"}], k},
          else: {t, a, k}

      {other, _} ->
        other
    end)
  end

  # Element ids end up in HTML attributes and CSS selectors. DMN ids are XML names, so anything
  # else (quotes, angle brackets, spaces) is refused here, at the only place they enter.
  defp check_ids(children) do
    bad =
      for {tag, a, _} <- children,
          @elements[local(tag)],
          id = attr(a, "id"),
          not Regex.match?(~r/\A[\w.\-]+\z/u, id),
          do: id

    case bad do
      [] ->
        :ok

      [id | _] ->
        {:error,
         "invalid element id #{inspect(String.slice(id, 0, 40))}: ids may only contain letters, digits, _, . and -"}
    end
  end

  defp build(attrs, children) do
    children = Enum.filter(children, &is_tuple/1)
    dropped = children |> Enum.map(&local(elem(&1, 0))) |> Enum.reject(&(&1 in @known_top)) |> Enum.frequencies()

    # a type remembers its name in the file, so that a rename is not taken for a delete and an insert
    types =
      for {tag, _, _} = e <- children, local(tag) == "itemDefinition", t = item(e), do: Map.put(t, :origin, t.name)

    # the prefixes this document gives our (earlier versions') test-value namespace
    spike = for {"xmlns:" <> p, uri} <- attrs, String.contains?(uri, "popcorn-dmn-spike"), do: p

    {nodes, notes} =
      for({tag, _, _} = e <- children, @elements[local(tag)], do: read_node(e, spike)) |> Enum.unzip()

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

    {authority, valid} =
      reqs.edges
      |> Enum.filter(fn {f, t, _} -> nodes[f] && nodes[t] end)
      |> Enum.split_with(&(elem(&1, 2) == :authority))

    {assoc, unresolved} = associations(children, nodes)
    links = Enum.uniq(assoc ++ authority)

    model = %Model{nodes: nodes, edges: valid, links: links, types: types, next: next_id(nodes)}
    model = place_missing(model, Enum.sort(missing))

    all_notes = Enum.flat_map(notes, & &1)

    {drg, other} = nodes |> Map.values() |> Enum.split_with(&(not Model.artifact?(&1)))

    report = %{
      name: attr(attrs, "name"),
      nodes: length(drg),
      artifacts: other |> Enum.frequencies_by(& &1.type),
      edges: length(valid),
      types: length(types),
      placed: length(missing),
      converted:
        merge_counts(
          %{},
          for(n <- all_notes, String.contains?(n, ": converted: "), do: String.replace(n, ": converted: ", ": "))
        ),
      # not shown or editable yet, but written back exactly as it was
      kept:
        Map.merge(dropped, reqs.dropped, fn _, a, b -> a + b end)
        |> merge_counts(List.duplicate("association to an unknown element", unresolved))
        |> merge_counts(for n <- all_notes, String.contains?(n, ": kept: "), do: String.replace(n, ": kept: ", ": "))
        |> merge_counts(if(extra_diagrams > 0, do: ["extra DMNDiagram"], else: [])),
      # really lost when the file is saved
      dropped:
        merge_counts(%{}, for({f, t, _} <- reqs.edges, !(nodes[f] && nodes[t]), do: "requirement to unknown element"))
    }

    {model, report}
  end

  # associations between two elements the editor knows; the rest stays in the file untouched
  defp associations(children, nodes) do
    all =
      for {tag, _, kids} = c <- children,
          local(tag) == "association",
          do: {c, ref_of(kids, "sourceRef"), ref_of(kids, "targetRef")}

    links = for {_, s, t} <- all, key = link_key(nodes, s, t), do: key
    {Enum.uniq(links), Enum.count(all, fn {_, s, t} -> link_key(nodes, s, t) == nil end)}
  end

  @doc "The model's key for an association between `s` and `t`, annotation first; nil when one of them is unknown."
  def link_key(nodes, s, t) do
    cond do
      nodes[s] == nil or nodes[t] == nil -> nil
      nodes[t].type == :annotation and nodes[s].type != :annotation -> {t, s, :association}
      true -> {s, t, :association}
    end
  end

  @doc false
  def ref_of(kids, tag) do
    case find(Enum.filter(kids, &is_tuple/1), tag) do
      nil -> nil
      {_, a, _} -> a |> attr("href") |> to_string() |> String.split("#") |> List.last()
    end
  end

  # keep file positions; with no diagram at all lay everything out, otherwise put the
  # shapeless elements in a row below the rest
  defp place_missing(model, []), do: model

  defp place_missing(%Model{nodes: nodes} = model, missing) when length(missing) == map_size(nodes),
    do: Layout.run(model)

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

  defp read_node({tag, attrs, kids}, spike) do
    kids = Enum.filter(kids, &is_tuple/1)
    type = @elements[local(tag)]
    id = attr(attrs, "id") || "n-#{:erlang.unique_integer([:positive])}"
    var = find(kids, "variable")
    {expr, expr_notes} = expression(type, kids, spike)
    name = if type == :annotation, do: text(find(kids, "text")) || "", else: attr(attrs, "name") || id

    n = %{
      id: id,
      type: type,
      name: name,
      description: find(kids, "description") |> text() || "",
      x: 0,
      y: 0,
      w: 150,
      h: 60,
      expr: expr,
      type_ref: var && attr(attrs_of(var), "typeRef")
    }

    {n, Enum.map(expr_notes, &"#{name}: #{&1}")}
  end

  defp expression(type, _kids, _spike) when type in [:annotation, :source, :group], do: {Model.artifact_expr(), []}

  # An input's test value used to be saved in an extension element of ours. Only that element counts (its
  # prefix is the one the document declares for our namespace): another vendor's `value` is not test data.
  defp expression(:input, kids, spike) do
    ours = Enum.map(spike, &(&1 <> ":value"))

    value =
      for({t, _, _} = c <- children(find(kids, "extensionElements") || {nil, [], []}), t in ours, do: text(c))
      |> List.first()

    {%{rows: [], result: value || ""}, []}
  end

  defp expression(:bkm, kids, spike) do
    case find(kids, "encapsulatedLogic") do
      nil ->
        {%{rows: [], result: "", params: []}, []}

      {_, _, lk} = logic ->
        params = for {t, a, _} <- Enum.filter(lk, &is_tuple/1), local(t) == "formalParameter", do: attr(a, "name")

        {body, notes} =
          case expression(:decision, children(logic), spike) do
            {%{kind: :table}, notes} ->
              {%{kind: :raw, tag: "decisionTable"},
               ["kept: decision table in a business knowledge model, read-only" | notes]}

            other ->
              other
          end

        {Map.put(body, :params, params), notes}
    end
  end

  defp expression(:decision, kids, _spike) do
    case first_expression(kids) do
      nil -> {%{rows: [], result: ""}, []}
      {:literal, t} -> {%{rows: [], result: t}, []}
      {:converted, t, note} -> {%{rows: [], result: t}, [note]}
      {:context, entries, notes} -> context_expr(entries, notes)
      {:table, t, notes} -> {t, notes}
      {:other, tag} -> {%{kind: :raw, tag: tag}, ["kept: #{tag} expression, read-only"]}
    end
  end

  @expr_tags [
    "literalExpression",
    "context",
    "decisionTable",
    "invocation",
    "relation",
    "functionDefinition",
    "list",
    "conditional",
    "filter",
    "for",
    "some",
    "every",
    "decisionTable"
  ]

  defp first_expression(kids) do
    case Enum.find(kids, fn
           {t, _, _} -> local(t) in @expr_tags
           _ -> false
         end) do
      {t, _, k} = e ->
        case local(t) do
          "literalExpression" -> {:literal, text(find(k, "text")) || ""}
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

        value =
          case first_expression(k) do
            {:literal, t} -> {t, []}
            {:converted, t, note} -> {t, [note]}
            nil -> {"", []}
            {:other, tag} -> {:raw, tag}
            _ -> {:raw, "nested expression"}
          end

        {var && attr(attrs_of(var), "name"), elem(value, 0), if(elem(value, 0) == :raw, do: [], else: elem(value, 1))}
      end

    # a context with an entry the editor cannot edit yet is kept whole, read-only, so nothing in it is lost
    case Enum.find(parsed, fn {_, t, _} -> t == :raw end) do
      {_, _, _} ->
        {%{kind: :raw, tag: "context"}, ["kept: context with an entry that cannot be edited yet, read-only"]}

      nil ->
        {named, unnamed} = Enum.split_with(parsed, fn {name, _, _} -> name != nil end)

        result =
          case unnamed do
            [{_, t, _} | _] -> t
            [] -> ""
          end

        extra = Enum.flat_map(parsed, &elem(&1, 2))
        {%{rows: Enum.map(named, fn {n, t, _} -> %{name: n, text: t} end), result: result}, notes ++ extra}
    end
  end

  # an aggregated COLLECT table (SUM, MIN, ...) would be evaluated as a plain COLLECT, which gives the wrong
  # value, so it is kept as it is in the file, read-only
  defp table({_, attrs, _} = e) do
    defaults? =
      for(
        {t, _, ok} <- children(e),
        local(t) == "output",
        {d, _, _} <- Enum.filter(ok, &is_tuple/1),
        local(d) == "defaultOutputEntry",
        do: d
      )
      |> Enum.any?()

    cond do
      agg = attr(attrs, "aggregation") -> {:other, "decisionTable with aggregation #{agg}"}
      # what the table returns when no rule matches is not modelled, so it would silently be null
      defaults? -> {:other, "decisionTable with a default output entry"}
      true -> editable_table(e)
    end
  end

  defp editable_table({_, attrs, kids}) do
    kids = Enum.filter(kids, &is_tuple/1)

    inputs =
      for {t, _, k} <- kids, local(t) == "input" do
        ie = find(k, "inputExpression")

        %{
          expr: ie |> children() |> find("text") |> text() |> Kernel.||(""),
          type_ref: ie && attr(attrs_of(ie), "typeRef")
        }
      end

    outputs =
      for {t, a, _} <- kids, local(t) == "output", do: %{name: attr(a, "name") || "", type_ref: attr(a, "typeRef")}

    outputs = if outputs == [], do: [%{name: "", type_ref: nil}], else: outputs
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
      if(length(annotations) > 1,
        do: ["kept: #{length(annotations) - 1} further annotation columns, not shown (kept until the table is edited)"],
        else: []
      )

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
      nil -> find(kids, "literalExpression") |> children() |> find("text") |> text() || ""
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
            "informationRequirement" ->
              add_req(acc, k, ["requiredDecision", "requiredInput"], to, :info, nodes)

            "knowledgeRequirement" ->
              add_req(acc, k, ["requiredKnowledge"], to, :knowledge, nodes)

            "authorityRequirement" ->
              add_req(acc, k, ["requiredAuthority", "requiredInput", "requiredDecision"], to, :authority, nodes)

            _ ->
              acc
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
      for {t, _, k} <- children,
          local(t) == "DMNDI",
          {t2, _, _} = d <- Enum.filter(k, &is_tuple/1),
          local(t2) == "DMNDiagram",
          do: d

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

  @doc false
  def local(name), do: name |> String.split(":") |> List.last()
  @doc false
  def attr(attrs, name), do: Enum.find_value(attrs, fn {k, v} -> if k == name or local(k) == name, do: v end)
  @doc false
  def children({_, _, kids}), do: Enum.filter(kids, &is_tuple/1)
  def children(nil), do: []
  @doc false
  def find(kids, name), do: Enum.find(kids, fn t -> is_tuple(t) and local(elem(t, 0)) == name end)

  @doc false
  def text(nil), do: nil
  def text({_, _, kids}), do: kids |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim()
end
