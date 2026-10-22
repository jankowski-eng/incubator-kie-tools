defmodule DmnSpike.Dmn.Overlay do
  @moduledoc """
  Keeps an imported file around the model so that saving it does not damage what the editor does not
  understand. The editor's model covers only part of DMN; everything else in a real file (comments,
  extension elements, ids, knowledge sources, annotations, diagram styles and labels, vendor attributes,
  namespace prefixes) would otherwise be lost on the first save.

  `build/6` records the original document next to the model. `to_xml/1` then writes it back:

    * elements nothing touched are written exactly as they were read;
    * an edited element is regenerated from the model, but keeps its own attributes, ids, prefixes and
      every child the editor does not model, in DMN's child order;
    * the diagram is rebuilt around the original shapes and edges, so styles and labels survive and only
      bounds and waypoints that really changed are rewritten;
    * elements added in the editor are generated in the file's own namespace prefixes.
  """

  alias DmnSpike.{Dmn, Model, Svg}

  @elements ~w(inputData decision businessKnowledgeModel textAnnotation knowledgeSource group)
  @expr_tags ~w(literalExpression context decisionTable invocation relation functionDefinition list conditional filter for some every)

  # the order of children DMN's schema prescribes (unknown children go before the expression)
  @rank %{
    decision:
      ~w(extensionElements description question allowedAnswers variable informationRequirement knowledgeRequirement authorityRequirement supportedObjective impactedPerformanceIndicator decisionMaker decisionOwner usingProcess usingTask),
    input: ~w(extensionElements description variable),
    source: ~w(extensionElements description type owner locationURI authorityRequirement),
    bkm: ~w(extensionElements description variable encapsulatedLogic knowledgeRequirement authorityRequirement),
    item: ~w(extensionElements description typeRef itemComponent allowedValues typeConstraint functionItem)
  }

  # ===================================================================== import side

  @doc "Records what is needed to write `model` back into the document it came from."
  def build(xml, root_tag, root_attrs, children, %Model{} = m, shapes) do
    {markers, _seen} =
      Enum.map_reduce(children, MapSet.new(), fn {tag, a, kids} = c, seen ->
        name = Dmn.local(tag)
        id = Dmn.attr(a, "id")

        key =
          name == "association" && Dmn.link_key(m.nodes, Dmn.ref_of(kids, "sourceRef"), Dmn.ref_of(kids, "targetRef"))

        cond do
          name in @elements and m.nodes[id] -> {{:node, id}, seen}
          name == "itemDefinition" and Dmn.attr(a, "name") -> {{:type, Dmn.attr(a, "name")}, seen}
          name == "DMNDI" -> {:dmndi, seen}
          key && not MapSet.member?(seen, key) -> {{:link, key}, MapSet.put(seen, key)}
          # a second association between the same two elements: it goes when the link goes
          key -> {{:duplicate, key, c}, seen}
          true -> {{:raw, c}, seen}
        end
      end)

    links =
      for {tag, a, kids} = c <- children,
          Dmn.local(tag) == "association",
          key = Dmn.link_key(m.nodes, Dmn.ref_of(kids, "sourceRef"), Dmn.ref_of(kids, "targetRef")),
          reduce: %{} do
        acc -> Map.put_new(acc, key, %{raw: c, id: Dmn.attr(a, "id")})
      end

    nodes =
      for {tag, a, _} = c <- children, Dmn.local(tag) in @elements, node = m.nodes[Dmn.attr(a, "id")], into: %{} do
        {node.id, %{raw: c, fp: fingerprint(m, node), efp: node.expr, reqs: req_ids(c)}}
      end

    types =
      for {tag, a, _} = c <- children,
          Dmn.local(tag) == "itemDefinition",
          name = Dmn.attr(a, "name"),
          t = Enum.find(m.types, &(&1.name == name)),
          into: %{} do
        {name, %{raw: c, type: t}}
      end

    %{
      prolog: prolog(xml),
      root_tag: root_tag,
      root_attrs: root_attrs,
      children: markers,
      links: links,
      nodes: nodes,
      types: types,
      diagram: %{
        raw: Enum.find(children, &(Dmn.local(elem(&1, 0)) == "DMNDI")),
        shapes: shapes,
        # what the diagram looked like when it was read: if it is the same on save, it is written back untouched
        snapshot: diagram_state(m)
      }
    }
  end

  # comments and processing instructions before the root element (typically the licence header)
  defp prolog(xml) do
    xml |> String.replace(~r/\A\s*<\?xml.*?\?>/s, "") |> prolog_items([]) |> Enum.reverse() |> Enum.join("\n")
  end

  defp prolog_items(rest, acc) do
    rest = String.trim_leading(rest)

    cond do
      String.starts_with?(rest, "<!--") ->
        take_until(rest, "-->", acc, &prolog_items/2)

      String.starts_with?(rest, "<?") ->
        take_until(rest, "?>", acc, &prolog_items/2)

      String.starts_with?(rest, "<!DOCTYPE") ->
        take_until(rest, ">", acc, fn r, a -> prolog_items(r, tl_doctype(a)) end)

      true ->
        acc
    end
  end

  # a DOCTYPE is skipped (it is dropped on save), so it is not added to the kept items
  defp tl_doctype(acc), do: tl(acc)

  defp take_until(text, stop, acc, next) do
    case String.split(text, stop, parts: 2) do
      [head, tail] -> next.(tail, [head <> stop | acc])
      _ -> acc
    end
  end

  defp diagram_state(m), do: {Map.new(m.nodes, fn {id, n} -> {id, bounds(n)} end), Enum.sort(Model.edges_all(m))}

  @doc "What decides whether an element has been edited: its modelled content and its incoming requirements."
  def fingerprint(%Model{} = m, node) do
    {node.name, node.type, node.type_ref, Model.description(node), node.expr,
     for({f, t, k} <- Model.edges_all(m), t == node.id, k != :association, do: {f, k}) |> Enum.sort()}
  end

  @req_tags %{
    "informationRequirement" => :info,
    "knowledgeRequirement" => :knowledge,
    "authorityRequirement" => :authority
  }

  defp req_ids({_, _, kids}) do
    for {t, a, rk} <- Enum.filter(kids, &is_tuple/1),
        kind = @req_tags[Dmn.local(t)],
        id = Dmn.attr(a, "id"),
        into: %{} do
      {{req_from(rk), kind}, id}
    end
  end

  defp req_from(kids) do
    Enum.find_value(kids, fn
      {_, a, _} -> a |> Dmn.attr("href") |> to_string() |> String.split("#") |> List.last()
      _ -> nil
    end)
  end

  # ===================================================================== export side

  def to_xml(%Model{doc: doc} = m) do
    pre = prefixes(doc)
    items = children_out(m, doc, pre)

    ids_out = items |> Enum.reject(&(&1 == :dmndi)) |> collect_ids() |> MapSet.new()

    out =
      Enum.map(items, fn
        :dmndi -> dmndi_el(m, doc, pre, ids_out)
        el -> el
      end)

    out =
      if Enum.any?(doc.children, &(&1 == :dmndi)) or not diagram_changed?(m, doc),
        do: out,
        else: out ++ [dmndi_el(m, doc, pre, ids_out)]

    root_attrs = ensure_decls(doc.root_attrs, out)
    header = ~s|<?xml version="1.0" encoding="UTF-8"?>\n| <> if(doc.prolog == "", do: "", else: doc.prolog <> "\n")
    header <> Dmn.render({:el, doc.root_tag, root_attrs, out}, 0)
  end

  # --- prefixes ---------------------------------------------------------------------

  defp prefixes(doc) do
    model =
      case String.split(doc.root_tag, ":") do
        [p, _] -> p <> ":"
        _ -> ""
      end

    uris = for {"xmlns:" <> p, uri} <- doc.root_attrs, into: %{}, do: {uri, p <> ":"}

    find = fn pattern, default ->
      Enum.find_value(uris, default, fn {uri, p} -> if Regex.match?(pattern, uri), do: p end)
    end

    %{
      model: model,
      dmndi: find.(~r/DMNDI/, "dmndi:"),
      dc: find.(~r{/DC/}, "dc:"),
      di: find.(~r{/DI/}, "di:"),
      kie: find.(~r{drools\.org/kie/dmn}, "kie:"),
      spike: find.(~r/popcorn-dmn-spike/, "spike:")
    }
  end

  # generated trees use unprefixed DMN names and dmndi:/dc:/di:/kie:/spike: for the rest; give them the file's prefixes
  defp q({:el, tag, attrs, kids}, pre) do
    {:el, qname(tag, pre, true), Enum.map(attrs, fn {k, v} -> {qname(k, pre, false), v} end),
     Enum.map(kids, fn k -> if is_binary(k), do: k, else: q(k, pre) end)}
  end

  defp qname("dmndi:" <> r, pre, _), do: pre.dmndi <> r
  defp qname("dc:" <> r, pre, _), do: pre.dc <> r
  defp qname("di:" <> r, pre, _), do: pre.di <> r
  defp qname("kie:" <> r, pre, _), do: pre.kie <> r
  defp qname("spike:" <> r, pre, _), do: pre.spike <> r
  defp qname(name, pre, true), do: pre.model <> name
  defp qname(name, _pre, false), do: name

  # a prefix that generated content uses but the root does not declare is declared
  defp ensure_decls(root_attrs, items) do
    declared = for {"xmlns:" <> p, _} <- root_attrs, into: MapSet.new(), do: p
    used = items |> Enum.flat_map(&prefixes_used/1) |> MapSet.new()

    Enum.reduce(MapSet.difference(used, declared), root_attrs, fn p, acc ->
      case Dmn.ns_uri(p) do
        nil -> acc
        uri -> acc ++ [{"xmlns:" <> p, uri}]
      end
    end)
  end

  defp prefixes_used({:el, tag, attrs, kids}) do
    own =
      for name <- [tag | Enum.map(attrs, &elem(&1, 0))],
          [p, _] <- [String.split(name, ":", parts: 2)],
          p != "xmlns",
          do: p

    own ++ Enum.flat_map(kids, fn k -> if is_binary(k), do: [], else: prefixes_used(k) end)
  end

  # --- raw <-> element trees -----------------------------------------------------------

  # Saxy simple form -> the writer's tree; whitespace between elements is dropped, text in leaves is kept
  def from_simple({tag, attrs, kids}) do
    elems = Enum.filter(kids, &is_tuple/1)
    {:el, tag, attrs, if(elems == [], do: kids, else: Enum.map(elems, &from_simple/1))}
  end

  defp collect_ids(items) do
    Enum.flat_map(items, fn {:el, _, attrs, kids} ->
      own = for {"id", v} <- attrs, do: v
      own ++ collect_ids(Enum.reject(kids, &is_binary/1))
    end)
  end

  defp put_attrs(attrs, pairs) do
    Enum.reduce(pairs, attrs, fn {k, v}, acc ->
      if List.keymember?(acc, k, 0), do: List.keyreplace(acc, k, 0, {k, v}), else: acc ++ [{k, v}]
    end)
  end

  defp sort_children(kids, kind) do
    order = @rank[kind]
    n = length(order)

    rank = fn {:el, tag, _, _} ->
      name = Dmn.local(tag)

      case Enum.find_index(order, &(&1 == name)) do
        nil -> if(name in @expr_tags, do: n + 1, else: n)
        i -> i
      end
    end

    Enum.sort_by(kids, rank)
  end

  # --- children of the root --------------------------------------------------------------

  defp children_out(m, doc, pre) do
    new_types =
      m.types
      |> Enum.reject(&Map.has_key?(doc.types, &1.name))
      |> Enum.with_index()
      |> Enum.map(fn {t, i} -> q(Dmn.item_xml(t, "_t-new#{i}-#{:erlang.phash2(t.name)}"), pre) end)

    new_nodes =
      m.nodes
      |> Map.values()
      |> Enum.reject(&Map.has_key?(doc.nodes, &1.id))
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&q(Dmn.node_xml(m, &1), pre))

    new_links =
      for({_, _, :association} = l <- m.links, not Map.has_key?(doc.links, l), do: l)
      |> Enum.map(&q(Dmn.link_xml(&1), pre))

    indexed = Enum.with_index(doc.children)
    idx = fn pred -> indexed |> Enum.filter(fn {mk, _} -> pred.(mk) end) |> Enum.map(&elem(&1, 1)) end
    type_idx = idx.(&match?({:type, _}, &1))
    node_idx = idx.(&match?({:node, _}, &1))
    dmndi_idx = idx.(&(&1 == :dmndi))

    types_at = insertion(type_idx, List.first(node_idx ++ dmndi_idx))
    nodes_at = insertion(node_idx, List.first(dmndi_idx))
    links_at = insertion(idx.(&match?({:link, _}, &1)), List.first(dmndi_idx))

    body =
      Enum.flat_map(indexed, fn {marker, i} ->
        before =
          if(types_at == {:before, i}, do: new_types, else: []) ++
            if(nodes_at == {:before, i}, do: new_nodes, else: []) ++
            if links_at == {:before, i}, do: new_links, else: []

        item =
          case marker do
            {:node, id} ->
              if(n = m.nodes[id], do: [node_el(m, doc, n, pre)], else: [])

            {:type, name} ->
              if(t = Enum.find(m.types, &(&1.name == name)), do: [type_el(doc.types[name], t, pre)], else: [])

            :dmndi ->
              [:dmndi]

            {:link, key} ->
              if key in m.links, do: [from_simple(doc.links[key].raw)], else: []

            {:duplicate, key, c} ->
              if key in m.links, do: [from_simple(c)], else: []

            {:raw, c} ->
              [from_simple(c)]
          end

        after_ =
          if(types_at == {:after, i}, do: new_types, else: []) ++
            if(nodes_at == {:after, i}, do: new_nodes, else: []) ++
            if links_at == {:after, i}, do: new_links, else: []

        before ++ item ++ after_
      end)

    body ++
      if(types_at == :end, do: new_types, else: []) ++
      if(nodes_at == :end, do: new_nodes, else: []) ++ if links_at == :end, do: new_links, else: []
  end

  # new elements go after the last element of their kind, else before `fallback`, else at the end
  defp insertion([], nil), do: :end
  defp insertion([], fallback), do: {:before, fallback}
  defp insertion(idx, _), do: {:after, List.last(idx)}

  # --- nodes ---------------------------------------------------------------------------------

  defp node_el(m, doc, node, pre) do
    case doc.nodes[node.id] do
      nil ->
        q(Dmn.node_xml(m, node), pre)

      %{raw: raw, fp: fp} = entry ->
        if fingerprint(m, node) == fp, do: from_simple(raw), else: regen_node(m, node, entry, pre)
    end
  end

  defp raw_requirements(raw),
    do: for({t, _, rk} = r <- raw, kind = @req_tags[Dmn.local(t)], into: %{}, do: {{req_from(rk), kind}, r})

  # incoming requirements, original elements where they still exist (ids and attributes kept), new ones generated
  defp requirements_out(m, node, raw_reqs, pre) do
    for {from, to, kind} <- Model.edges_all(m), to == node.id, kind != :association do
      case raw_reqs[{from, kind}] do
        nil -> q(Dmn.req_xml(m, from, to, kind), pre)
        r -> from_simple(r)
      end
    end
  end

  defp fresh_description(node, pre),
    do: if(Model.description(node) == "", do: [], else: [q(Dmn.el("description", [], [node.description]), pre)])

  # a group has a name and nothing else the editor models; its documentation and extensions stay
  defp regen_node(_m, %{type: :group} = node, %{raw: {tag, attrs, kids}}, _pre),
    do:
      {:el, tag, put_attrs(attrs, [{"id", node.id}, {"name", node.name}]),
       for(r <- kids, is_tuple(r), do: from_simple(r))}

  defp regen_node(m, %{type: :source} = node, %{raw: {tag, attrs, kids}}, pre) do
    raw = Enum.filter(kids, &is_tuple/1)
    named = fn name -> Enum.filter(raw, &(Dmn.local(elem(&1, 0)) == name)) end
    reqs = requirements_out(m, node, raw_requirements(raw), pre)

    description =
      case named.("description") do
        [r | _] ->
          if Dmn.text(r) == Model.description(node),
            do: [from_simple(r)],
            else: fresh_description(node, pre)

        [] ->
          fresh_description(node, pre)
      end

    others = for r <- raw, Dmn.local(elem(r, 0)) not in ["description", "authorityRequirement"], do: from_simple(r)
    attrs = put_attrs(attrs, [{"id", node.id}, {"name", node.name}])
    {:el, tag, attrs, sort_children(description ++ reqs ++ others, :source)}
  end

  defp regen_node(_m, %{type: :annotation} = node, %{raw: {tag, attrs, kids}}, pre) do
    raw = Enum.filter(kids, &is_tuple/1)
    others = for r <- raw, Dmn.local(elem(r, 0)) != "text", do: from_simple(r)

    text =
      case Enum.find(raw, &(Dmn.local(elem(&1, 0)) == "text")) do
        {_, _, _} = t ->
          if Dmn.text(t) == node.name, do: from_simple(t), else: {:el, elem(t, 0), elem(t, 1), [node.name]}

        nil ->
          q(Dmn.el("text", [], [node.name]), pre)
      end

    {:el, tag, put_attrs(attrs, [{"id", node.id}]), others ++ [text]}
  end

  defp regen_node(m, node, %{raw: {tag, attrs, kids}, efp: efp}, pre) do
    raw = Enum.filter(kids, &is_tuple/1)
    named = fn name -> Enum.filter(raw, &(Dmn.local(elem(&1, 0)) == name)) end
    {:el, _, _, fresh_kids} = q(Dmn.node_xml(m, node), pre)
    fresh = fn name -> Enum.filter(fresh_kids, fn {:el, t, _, _} -> Dmn.local(t) == name end) end

    variable =
      case named.("variable") do
        [{vt, va, _} | _] ->
          va = va |> Enum.reject(&match?({"typeRef", _}, &1)) |> put_attrs([{"name", node.name}])
          [{:el, vt, if(node.type_ref, do: va ++ [{"typeRef", node.type_ref}], else: va), []}]

        [] ->
          fresh.("variable")
      end

    raw_reqs = raw_requirements(raw)
    reqs = requirements_out(m, node, raw_reqs, pre)

    expression =
      cond do
        node.type == :input ->
          []

        node.expr == efp ->
          for r <- raw,
              Dmn.local(elem(r, 0)) in @expr_tags or Dmn.local(elem(r, 0)) == "encapsulatedLogic",
              do: from_simple(r)

        true ->
          fresh.("literalExpression") ++ fresh.("context") ++ fresh.("decisionTable") ++ fresh.("encapsulatedLogic")
      end

    extension =
      if node.type == :input,
        do: input_extension(node, named.("extensionElements"), pre),
        else: Enum.map(named.("extensionElements"), &from_simple/1)

    handled =
      [
        "variable",
        "description",
        "informationRequirement",
        "knowledgeRequirement",
        "authorityRequirement",
        "extensionElements",
        "encapsulatedLogic"
      ] ++
        @expr_tags

    # an unchanged description keeps its original element (attributes included)
    description =
      case named.("description") do
        [r | _] -> if(Dmn.text(r) == Model.description(node), do: [from_simple(r)], else: fresh.("description"))
        [] -> fresh.("description")
      end

    others = for r <- raw, Dmn.local(elem(r, 0)) not in handled, do: from_simple(r)
    kind = %{input: :input, decision: :decision, bkm: :bkm}[node.type]

    attrs = put_attrs(attrs, [{"id", node.id}, {"name", node.name}])
    {:el, tag, attrs, sort_children(extension ++ description ++ variable ++ reqs ++ expression ++ others, kind)}
  end

  # the value of an input data node lives in our own extension element; other extension content is kept
  defp input_extension(node, existing, pre) do
    ours = if node.expr.result == "", do: [], else: [q({:el, "spike:value", [], [node.expr.result]}, pre)]

    case existing do
      [] ->
        if ours == [], do: [], else: [{:el, pre.model <> "extensionElements", [], ours}]

      [{t, a, k} | _] ->
        kept =
          for c <- Enum.filter(k, &is_tuple/1),
              Dmn.local(elem(c, 0)) != "value" or not String.contains?(elem(c, 0), "spike"),
              do: from_simple(c)

        content = kept ++ ours
        if content == [], do: [], else: [{:el, t, a, content}]
    end
  end

  # --- types -----------------------------------------------------------------------------------

  defp type_el(%{raw: raw, type: original}, type, pre) do
    if type == original, do: from_simple(raw), else: regen_type(raw, type, pre)
  end

  defp regen_type({tag, attrs, kids}, type, pre) do
    raw = Enum.filter(kids, &is_tuple/1)
    id = Dmn.attr(attrs, "id") || "_t-#{:erlang.phash2(type.name)}"
    {:el, _, _, fresh_kids} = q(Dmn.item_xml(type, id), pre)
    handled = ["typeRef", "itemComponent", "allowedValues", "typeConstraint"]
    others = for r <- raw, Dmn.local(elem(r, 0)) not in handled, do: from_simple(r)

    attrs = put_attrs(attrs, [{"name", type.name}])

    attrs =
      cond do
        type.collection -> put_attrs(attrs, [{"isCollection", "true"}])
        List.keymember?(attrs, "isCollection", 0) -> put_attrs(attrs, [{"isCollection", "false"}])
        true -> attrs
      end

    {:el, tag, attrs, sort_children(fresh_kids ++ others, :item)}
  end

  # --- the diagram -------------------------------------------------------------------------------

  defp bounds(n), do: {n.x, n.y, n.w, n.h}

  defp diagram_changed?(m, doc), do: diagram_state(m) != doc.diagram.snapshot

  defp dmndi_el(m, doc, pre, ids_out) do
    if diagram_changed?(m, doc), do: rebuild_diagram(m, doc, pre, ids_out), else: from_simple(doc.diagram.raw)
  end

  defp rebuild_diagram(m, doc, pre, ids_out) do
    # the requirement ids in the output, per edge
    expected =
      for {from, to, kind} <- Model.edges_all(m), into: %{} do
        rid =
          case kind do
            :association -> get_in(doc.links, [{from, to, kind}, :id]) || Dmn.link_id(from, to)
            _ -> get_in(doc.nodes, [to, :reqs, {from, kind}]) || Dmn.req_id(from, to)
          end

        {rid, {from, to}}
      end

    orig_shapes = doc.diagram.shapes

    case doc.diagram.raw do
      nil ->
        shapes = for n <- sorted_nodes(m), do: new_shape(n, pre)
        edges = for {rid, {f, t}} <- expected, do: new_edge(m, rid, f, t, pre)
        {:el, pre.dmndi <> "DMNDI", [], [{:el, pre.dmndi <> "DMNDiagram", [{"id", "_diagram"}], shapes ++ edges}]}

      {dtag, dattrs, dkids} ->
        kids = Enum.filter(dkids, &is_tuple/1)

        {{gtag, gattrs, gkids}, rest} =
          case Enum.split_with(kids, &(Dmn.local(elem(&1, 0)) == "DMNDiagram")) do
            {[first | more], others} -> {first, more ++ others}
            {[], others} -> {{pre.dmndi <> "DMNDiagram", [{"id", "_diagram"}], []}, others}
          end

        moved? = fn id ->
          case {m.nodes[id], orig_shapes[id]} do
            {n, b} when n != nil and b != nil -> bounds(n) != b
            _ -> true
          end
        end

        kept =
          for {t, a, k} = c <- Enum.filter(gkids, &is_tuple/1) do
            ref = Dmn.attr(a, "dmnElementRef")

            case Dmn.local(t) do
              "DMNShape" ->
                cond do
                  doc.nodes[ref] != nil and m.nodes[ref] == nil ->
                    nil

                  m.nodes[ref] != nil and doc.nodes[ref] != nil and moved?.(ref) ->
                    from_simple({t, a, update_bounds(k, bounds(m.nodes[ref]))})

                  true ->
                    from_simple(c)
                end

              "DMNEdge" ->
                cond do
                  Map.has_key?(expected, ref) ->
                    {f, to} = expected[ref]
                    if moved?.(f) or moved?.(to), do: regen_waypoints({t, a, k}, m, f, to, pre), else: from_simple(c)

                  MapSet.member?(ids_out, ref) ->
                    from_simple(c)

                  true ->
                    nil
                end

              _ ->
                # e.g. KIE's extension with column widths: entries that point at deleted elements go with them
                c |> prune_refs(ids_out) |> from_simple()
            end
          end
          |> Enum.reject(&is_nil/1)

        present_shapes =
          for {t, a, _} <- Enum.filter(gkids, &is_tuple/1), Dmn.local(t) == "DMNShape", do: Dmn.attr(a, "dmnElementRef")

        present_edges =
          for {t, a, _} <- Enum.filter(gkids, &is_tuple/1), Dmn.local(t) == "DMNEdge", do: Dmn.attr(a, "dmnElementRef")

        new_shapes = for n <- sorted_nodes(m), n.id not in present_shapes, do: new_shape(n, pre)
        new_edges = for {rid, {f, t}} <- Enum.sort(expected), rid not in present_edges, do: new_edge(m, rid, f, t, pre)

        diagram = {:el, gtag, gattrs, kept ++ new_shapes ++ new_edges}
        {:el, dtag, dattrs, [diagram | Enum.map(rest, &(&1 |> prune_refs(ids_out) |> from_simple()))]}
    end
  end

  defp prune_refs({t, a, k}, ids),
    do: {t, a, for(c <- k, keep_ref?(c, ids), do: if(is_tuple(c), do: prune_refs(c, ids), else: c))}

  defp keep_ref?(c, ids) when is_tuple(c) do
    case Dmn.attr(elem(c, 1), "dmnElementRef") do
      nil -> true
      ref -> MapSet.member?(ids, ref)
    end
  end

  defp keep_ref?(_text, _ids), do: true

  defp sorted_nodes(m), do: m.nodes |> Map.values() |> Enum.sort_by(& &1.id)

  defp update_bounds(kids, {x, y, w, h}) do
    Enum.map(kids, fn
      {t, a, k} = c ->
        if Dmn.local(t) == "Bounds",
          do: {t, put_attrs(a, [{"x", x}, {"y", y}, {"width", w}, {"height", h}]), k},
          else: c

      other ->
        other
    end)
  end

  defp regen_waypoints({t, a, k}, m, from, to, pre) do
    {x1, y1, x2, y2} = Svg.endpoints(m.nodes[from], m.nodes[to])

    wp =
      Enum.find_value(k, pre.di <> "waypoint", fn c ->
        if is_tuple(c) and Dmn.local(elem(c, 0)) == "waypoint", do: elem(c, 0)
      end)

    others = for c <- k, is_tuple(c), Dmn.local(elem(c, 0)) != "waypoint", do: from_simple(c)

    {:el, t, a,
     [{:el, wp, [{"x", round(x1)}, {"y", round(y1)}], []}, {:el, wp, [{"x", round(x2)}, {"y", round(y2)}], []}] ++
       others}
  end

  defp new_shape(n, pre) do
    q(
      {:el, "dmndi:DMNShape", [{"id", "dmnshape-drg-#{n.id}"}, {"dmnElementRef", n.id}, {"isCollapsed", "false"}],
       [{:el, "dc:Bounds", [{"x", n.x}, {"y", n.y}, {"width", n.w}, {"height", n.h}], []}]},
      pre
    )
  end

  defp new_edge(m, rid, from, to, pre) do
    {x1, y1, x2, y2} = Svg.endpoints(m.nodes[from], m.nodes[to])

    q(
      {:el, "dmndi:DMNEdge", [{"id", "dmnedge-drg-#{rid}"}, {"dmnElementRef", rid}],
       [
         {:el, "di:waypoint", [{"x", round(x1)}, {"y", round(y1)}], []},
         {:el, "di:waypoint", [{"x", round(x2)}, {"y", round(y2)}], []}
       ]},
      pre
    )
  end
end
