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

  # the order of children DMN's schema prescribes (DMN16.xsd: tDMNElement is description, then
  # extensionElements); unknown children go before the expression
  @rank %{
    decision:
      ~w(description extensionElements question allowedAnswers variable informationRequirement knowledgeRequirement authorityRequirement supportedObjective impactedPerformanceIndicator decisionMaker decisionOwner usingProcess usingTask),
    input: ~w(description extensionElements variable),
    source: ~w(description extensionElements authorityRequirement type owner locationURI),
    bkm: ~w(description extensionElements variable encapsulatedLogic knowledgeRequirement authorityRequirement),
    item: ~w(description extensionElements typeRef allowedValues typeConstraint itemComponent functionItem)
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
      # every id the file uses, so that nothing generated can collide with it
      ids: MapSet.new(simple_ids(children)),
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
    # the value of an input is test data (a scenario), not part of the file, so it does not count as an edit
    expr = if node.type == :input, do: nil, else: node.expr

    {node.name, node.type, node.type_ref, Model.description(node), expr,
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

  # the element a requirement points at; children without an href (a description, extensions) are skipped
  defp req_from(kids) do
    Enum.find_value(kids, fn
      {_, a, _} -> if href = Dmn.attr(a, "href"), do: href |> String.split("#") |> List.last()
      _ -> nil
    end)
  end

  # ===================================================================== export side

  def to_xml(%Model{} = m) do
    {header, root} = document(m)
    header <> Dmn.render(root, 0)
  end

  @doc "The document as `{header, root element}`: what `to_xml/1` writes, before it is turned into text."
  def document(%Model{doc: doc} = m) do
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

    out = rename_type_refs(out, renamed_types(m))
    root_attrs = ensure_decls(doc.root_attrs, out)
    header = ~s|<?xml version="1.0" encoding="UTF-8"?>\n| <> if(doc.prolog == "", do: "", else: doc.prolog <> "\n")
    {header, {:el, doc.root_tag, root_attrs, out}}
  end

  # --- type references the file keeps --------------------------------------------------

  @doc """
  `{node name, type name}` for type references that are written back from the original file and not from
  the model: everything in a node that is saved as it was read, and the formal parameters and read-only
  expressions of a node that was edited. Deleted nodes have no say. Used to keep a type that only such a
  reference uses from being deleted.
  """
  def retained_type_refs(%Model{doc: nil}), do: []

  def retained_type_refs(%Model{doc: doc} = m) do
    for {id, %{raw: raw, fp: fp}} <- doc.nodes,
        node = m.nodes[id],
        ref <- if(fingerprint(m, node) == fp, do: type_refs(raw), else: kept_refs(raw, node)),
        do: {node.name, ref}
  end

  defp kept_refs({_, _, kids}, node) do
    raw = for k <- kids, is_tuple(k), do: k
    params = for r <- raw, p <- descendants(r, "formalParameter"), ref <- type_refs(p), do: ref

    expression =
      if match?(%{kind: :raw}, node.expr),
        do: for(r <- raw, Dmn.local(elem(r, 0)) in @expr_tags, ref <- type_refs(r), do: ref),
        else: []

    params ++ expression
  end

  defp descendants({tag, _, kids} = e, name) do
    own = if Dmn.local(tag) == name, do: [e], else: []
    own ++ Enum.flat_map(kids, fn k -> if is_tuple(k), do: descendants(k, name), else: [] end)
  end

  defp type_refs({tag, attrs, kids}) do
    own = for {k, v} <- attrs, Dmn.local(k) == "typeRef", v != "", do: v

    text =
      if Dmn.local(tag) == "typeRef", do: [kids |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim()], else: []

    own ++ text ++ Enum.flat_map(kids, fn k -> if is_tuple(k), do: type_refs(k), else: [] end)
  end

  # --- renamed types -----------------------------------------------------------------

  # imported types remember the name they had in the file (`origin`); a rename must also reach the
  # references that are written back untouched (inputExpression/output/formalParameter typeRef, ...)
  defp renamed_types(m) do
    current = MapSet.new(m.types, & &1.name)

    for %{origin: old, name: new} <- m.types, old != new, not MapSet.member?(current, old), into: %{}, do: {old, new}
  end

  defp rename_type_refs(items, map) when map_size(map) == 0, do: items

  defp rename_type_refs(items, map) do
    Enum.map(items, fn
      {:el, tag, attrs, kids} ->
        attrs = for {k, v} <- attrs, do: {k, if(Dmn.local(k) == "typeRef", do: Map.get(map, v, v), else: v)}

        kids =
          case {Dmn.local(tag), kids} do
            {"typeRef", [text]} when is_binary(text) -> [Map.get(map, String.trim(text), text)]
            _ -> rename_type_refs(kids, map)
          end

        {:el, tag, attrs, kids}

      other ->
        other
    end)
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

  # Saxy simple form -> the writer's tree. Whitespace between elements is dropped and text in leaves is kept;
  # text mixed with elements is meaningful, so it is kept, in order.
  def from_simple({tag, attrs, kids}) do
    elems = Enum.filter(kids, &is_tuple/1)

    kids =
      cond do
        elems == [] -> kids
        Enum.any?(kids, &(is_binary(&1) and String.trim(&1) != "")) -> Enum.map(kids, &mixed_child/1)
        true -> Enum.map(elems, &from_simple/1)
      end

    {:el, tag, attrs, kids}
  end

  defp mixed_child(k) when is_tuple(k), do: from_simple(k)
  defp mixed_child(text), do: text

  defp kept_children(kids), do: for(k <- kids, is_tuple(k), do: from_simple(k))

  defp simple_ids(items) do
    Enum.flat_map(items, fn
      {_, attrs, kids} -> for({"id", v} <- attrs, do: v) ++ simple_ids(Enum.filter(kids, &is_tuple/1))
      _ -> []
    end)
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
      |> Enum.reject(&Map.has_key?(doc.types, Map.get(&1, :origin)))
      |> Enum.with_index()
      |> Enum.map(fn {t, i} -> q(Dmn.item_xml(t, "_t-new#{i}-#{:erlang.phash2(t.name)}"), pre) end)

    # definitions holds the DRG elements (decisions, inputs, business knowledge, knowledge sources) before the
    # artifacts (annotations, groups, associations): new elements go into their own section
    {new_art_nodes, new_drg_nodes} =
      m.nodes
      |> Map.values()
      |> Enum.reject(&Map.has_key?(doc.nodes, &1.id))
      |> Enum.sort_by(& &1.id)
      |> Enum.split_with(&xml_artifact?/1)

    new_drg = Enum.map(new_drg_nodes, &q(Dmn.node_xml(m, &1), pre))

    new_links =
      for({_, _, :association} = l <- m.links, not Map.has_key?(doc.links, l), do: l)
      |> Enum.map(&q(Dmn.link_xml(&1), pre))

    new_art = Enum.map(new_art_nodes, &q(Dmn.node_xml(m, &1), pre)) ++ new_links

    indexed = Enum.with_index(doc.children)
    idx = fn pred -> indexed |> Enum.filter(fn {mk, _} -> pred.(mk) end) |> Enum.map(&elem(&1, 1)) end

    artifact_marker? = fn
      {:node, id} -> doc.nodes[id] != nil and Dmn.local(elem(doc.nodes[id].raw, 0)) in ["textAnnotation", "group"]
      {:link, _} -> true
      {:duplicate, _, _} -> true
      _ -> false
    end

    type_idx = idx.(&match?({:type, _}, &1))
    art_idx = idx.(artifact_marker?)
    drg_idx = idx.(&(match?({:node, _}, &1) and not artifact_marker?.(&1)))
    dmndi_idx = idx.(&(&1 == :dmndi))
    first = fn list -> if list == [], do: nil, else: Enum.min(list) end

    types_at = insertion(type_idx, first.(drg_idx ++ art_idx ++ dmndi_idx))
    drg_at = insertion(drg_idx, first.(art_idx ++ dmndi_idx))
    art_at = insertion(art_idx, first.(dmndi_idx))

    body =
      Enum.flat_map(indexed, fn {marker, i} ->
        before =
          if(types_at == {:before, i}, do: new_types, else: []) ++
            if(drg_at == {:before, i}, do: new_drg, else: []) ++
            if art_at == {:before, i}, do: new_art, else: []

        item =
          case marker do
            {:node, id} ->
              if(n = m.nodes[id], do: [node_el(m, doc, n, pre)], else: [])

            {:type, name} ->
              if(t = Enum.find(m.types, &(Map.get(&1, :origin) == name)),
                do: [type_el(doc.types[name], t, pre)],
                else: []
              )

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
            if(drg_at == {:after, i}, do: new_drg, else: []) ++
            if art_at == {:after, i}, do: new_art, else: []

        before ++ item ++ after_
      end)

    body ++
      if(types_at == :end, do: new_types, else: []) ++
      if(drg_at == :end, do: new_drg, else: []) ++ if art_at == :end, do: new_art, else: []
  end

  defp xml_artifact?(%{type: type}), do: type in [:annotation, :group]

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
        if fingerprint(m, node) == fp and not legacy_value?(raw, pre),
          do: from_simple(raw),
          else: regen_node(m, node, entry, pre)
    end
  end

  # files saved by earlier versions hold an input's test value in an extension element; saving drops it
  defp legacy_value?({_, _, kids}, pre) do
    Enum.any?(kids, fn
      {t, _, ext} ->
        Dmn.local(t) == "extensionElements" and
          Enum.any?(ext, &match?({tag, _, _} when tag == pre.spike <> "value", &1))

      _ ->
        false
    end)
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

  # an unchanged description keeps its original element (attributes included)
  defp description_out([r | _], node, pre) do
    if Dmn.text(r) == Model.description(node), do: [from_simple(r)], else: fresh_description(node, pre)
  end

  defp description_out([], node, pre), do: fresh_description(node, pre)

  defp fresh_description(node, pre),
    do: if(Model.description(node) == "", do: [], else: [q(Dmn.el("description", [], [node.description]), pre)])

  # a group has a name and nothing else the editor models; its documentation and extensions stay
  defp regen_node(_m, %{type: :group} = node, %{raw: {tag, attrs, kids}}, pre) do
    raw = for r <- kids, is_tuple(r), do: r
    description = description_out(Enum.filter(raw, &(Dmn.local(elem(&1, 0)) == "description")), node, pre)
    others = for r <- raw, Dmn.local(elem(r, 0)) != "description", do: from_simple(r)
    {:el, tag, put_attrs(attrs, [{"id", node.id}, {"name", node.name}]), description ++ others}
  end

  defp regen_node(m, %{type: :source} = node, %{raw: {tag, attrs, kids}}, pre) do
    raw = Enum.filter(kids, &is_tuple/1)
    named = fn name -> Enum.filter(raw, &(Dmn.local(elem(&1, 0)) == name)) end
    reqs = requirements_out(m, node, raw_requirements(raw), pre)

    description = description_out(named.("description"), node, pre)

    others = for r <- raw, Dmn.local(elem(r, 0)) not in ["description", "authorityRequirement"], do: from_simple(r)
    attrs = put_attrs(attrs, [{"id", node.id}, {"name", node.name}])
    {:el, tag, attrs, sort_children(description ++ reqs ++ others, :source)}
  end

  defp regen_node(_m, %{type: :annotation} = node, %{raw: {tag, attrs, kids}}, pre) do
    raw = Enum.filter(kids, &is_tuple/1)
    others = for r <- raw, Dmn.local(elem(r, 0)) not in ["text", "description"], do: from_simple(r)

    text =
      case Enum.find(raw, &(Dmn.local(elem(&1, 0)) == "text")) do
        {_, _, _} = t ->
          if Dmn.text(t) == node.name, do: from_simple(t), else: {:el, elem(t, 0), elem(t, 1), [node.name]}

        nil ->
          q(Dmn.el("text", [], [node.name]), pre)
      end

    description = description_out(Enum.filter(raw, &(Dmn.local(elem(&1, 0)) == "description")), node, pre)
    {:el, tag, put_attrs(attrs, [{"id", node.id}]), description ++ others ++ [text]}
  end

  defp regen_node(m, node, %{raw: {tag, attrs, kids}, efp: efp}, pre) do
    raw = Enum.filter(kids, &is_tuple/1)
    named = fn name -> Enum.filter(raw, &(Dmn.local(elem(&1, 0)) == name)) end
    {:el, _, _, fresh_kids} = q(Dmn.node_xml(m, node), pre)
    fresh = fn name -> Enum.filter(fresh_kids, fn {:el, t, _, _} -> Dmn.local(t) == name end) end

    variable =
      case named.("variable") do
        [{vt, va, vk} | _] ->
          va = va |> Enum.reject(&match?({"typeRef", _}, &1)) |> put_attrs([{"name", node.name}])
          # the variable's own description and extensions stay
          [{:el, vt, if(node.type_ref, do: va ++ [{"typeRef", node.type_ref}], else: va), kept_children(vk)}]

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
          raw_expr =
            Enum.filter(raw, &(Dmn.local(elem(&1, 0)) in @expr_tags or Dmn.local(elem(&1, 0)) == "encapsulatedLogic"))

          fresh_expr =
            fresh.("literalExpression") ++ fresh.("context") ++ fresh.("decisionTable") ++ fresh.("encapsulatedLogic")

          # the model decides the text and the structure; the original keeps its ids, typeRefs and unknown children
          for f <- fresh_expr do
            case Enum.find(raw_expr, &(Dmn.local(elem(&1, 0)) == Dmn.local(elem(f, 1)))) do
              nil -> f
              r -> merge(f, r)
            end
          end
      end

    extension =
      if node.type == :input,
        do: input_extension(named.("extensionElements"), pre),
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
    description = description_out(named.("description"), node, pre)

    others = for r <- raw, Dmn.local(elem(r, 0)) not in handled, do: from_simple(r)
    kind = %{input: :input, decision: :decision, bkm: :bkm}[node.type]

    attrs = put_attrs(attrs, [{"id", node.id}, {"name", node.name}])
    {:el, tag, attrs, sort_children(extension ++ description ++ variable ++ reqs ++ expression ++ others, kind)}
  end

  # attributes the model owns: when the regenerated element has none, the original's is gone on purpose
  # (a column's typeRef is modelled now: a new table that merely sits where an old one was must not inherit it)
  @owned ~w(name hitPolicy)
  @owned_by_tag %{"inputExpression" => ~w(typeRef), "output" => ~w(name typeRef)}

  # Merges a regenerated element into the original it replaces, by tag and position. Only where the number
  # of children with a tag is unchanged (a deleted column or rule would shift the positions and attach
  # another one's ids and typeRef), otherwise the regenerated children are used as they are.
  defp merge({:el, tag, fattrs, fkids}, {_, rattrs, rkids}) do
    owned = Map.get(@owned_by_tag, Dmn.local(tag), @owned)
    kept = Enum.reject(rattrs, fn {k, _} -> Dmn.local(k) in owned and not List.keymember?(fattrs, k, 0) end)
    attrs = Enum.reduce(fattrs, kept, &put_attrs(&2, [&1]))
    {:el, tag, attrs, merge_children(Dmn.local(tag), fkids, for(k <- rkids, is_tuple(k), do: k))}
  end

  # A text leaf has text children; an element with no children at all (a table `output`) is structural and
  # keeps what the original had besides.
  defp merge_children(parent, fkids, rkids) do
    if fkids != [] and Enum.all?(fkids, &is_binary/1), do: fkids, else: merge_elements(parent, fkids, rkids)
  end

  # Children the model produces itself, per parent. When the regenerated element has none of a kind, the
  # model removed them (the last rule, all parameters) and the original's must not come back.
  @owned %{
    "decisionTable" => ~w(input output annotation rule),
    "rule" => ~w(inputEntry outputEntry annotationEntry),
    "input" => ~w(inputExpression),
    "inputExpression" => ~w(text),
    "inputEntry" => ~w(text),
    "outputEntry" => ~w(text),
    "annotationEntry" => ~w(text),
    "encapsulatedLogic" => ~w(formalParameter) ++ @expr_tags,
    "context" => ~w(contextEntry),
    "contextEntry" => ~w(variable) ++ @expr_tags,
    "literalExpression" => ~w(text)
  }

  # DMN16.xsd child order of the elements merged here; tDMNElement's description and extensionElements
  # always come first, anything not listed after the listed ones
  @order %{
    "decisionTable" => ~w(description extensionElements input output annotation rule),
    "rule" => ~w(description extensionElements inputEntry outputEntry annotationEntry),
    "input" => ~w(description extensionElements inputExpression inputValues),
    "output" => ~w(description extensionElements outputValues defaultOutputEntry),
    "encapsulatedLogic" => ~w(description extensionElements formalParameter),
    "context" => ~w(description extensionElements contextEntry),
    "contextEntry" => ~w(description extensionElements variable),
    "literalExpression" => ~w(description extensionElements text importedValues)
  }

  defp child_rank(parent, name) do
    order = Map.get(@order, parent, ~w(description extensionElements))
    Enum.find_index(order, &(&1 == name)) || length(order)
  end

  defp merge_elements(parent, fkids, rkids) do
    # regenerated elements are {:el, tag, attrs, kids}, the original's are Saxy's {tag, attrs, kids}
    fresh_by = Enum.group_by(fkids, &Dmn.local(elem(&1, 1)))
    raw_by = Enum.group_by(rkids, &Dmn.local(elem(&1, 0)))
    # unmodelled children of the original (description, extensionElements, ...) come first, as in the schema
    owned = Map.get(@owned, parent, [])

    unknown =
      for r <- rkids,
          name = Dmn.local(elem(r, 0)),
          not Map.has_key?(fresh_by, name) and name not in owned,
          do: from_simple(r)

    {merged, _} =
      Enum.map_reduce(fkids, %{}, fn {:el, t, _, _} = f, seen ->
        name = Dmn.local(t)
        i = Map.get(seen, name, 0)
        raws = Map.get(raw_by, name, [])

        same_count? = length(raws) == length(Map.fetch!(fresh_by, name))
        merged = if same_count? and Enum.at(raws, i), do: merge(f, Enum.at(raws, i)), else: f

        {merged, Map.put(seen, name, i + 1)}
      end)

    # a stable sort keeps the regenerated children in order among themselves
    Enum.sort_by(unknown ++ merged, fn {:el, t, _, _} -> child_rank(parent, Dmn.local(t)) end)
  end

  # an input's test value used to be written into an extension element of ours; it is dropped now (the
  # value belongs to a scenario) and the other extension content is kept
  defp input_extension(existing, pre) do
    case existing do
      [] ->
        []

      [{t, a, k} | _] ->
        kept = for c <- Enum.filter(k, &is_tuple/1), elem(c, 0) != pre.spike <> "value", do: from_simple(c)
        if kept == [], do: [], else: [{:el, t, a, kept}]
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
    if diagram_changed?(m, doc) or dangling?(doc, ids_out),
      do: rebuild_diagram(m, doc, pre, ids_out),
      else: from_simple(doc.diagram.raw)
  end

  # An edit can remove an element the untouched diagram still points at (a regenerated expression loses
  # its id, and with it KIE's column widths entry). Only references to ids the file had and no longer
  # has count: references that were dangling in the file are not ours to clean up.
  defp dangling?(%{diagram: %{raw: nil}}, _ids_out), do: false

  defp dangling?(doc, ids_out) do
    lost = MapSet.difference(doc.ids, ids_out)
    lost != MapSet.new() and Enum.any?(refs(doc.diagram.raw), &MapSet.member?(lost, &1))
  end

  defp refs({_, attrs, kids}),
    do:
      for({"dmnElementRef", v} <- attrs, do: v) ++
        Enum.flat_map(kids, fn k -> if is_tuple(k), do: refs(k), else: [] end)

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
    {x1, y1, x2, y2} = Svg.endpoints(m, from, to)

    wp =
      Enum.find_value(k, pre.di <> "waypoint", fn c ->
        if is_tuple(c) and Dmn.local(elem(c, 0)) == "waypoint", do: elem(c, 0)
      end)

    others = for c <- k, is_tuple(c), Dmn.local(elem(c, 0)) != "waypoint", do: from_simple(c)
    # DI order: extension and style, then the waypoints, then the label
    {label, before} = Enum.split_with(others, &(Dmn.local(elem(&1, 1)) == "DMNLabel"))

    {:el, t, a,
     before ++
       [{:el, wp, [{"x", round(x1)}, {"y", round(y1)}], []}, {:el, wp, [{"x", round(x2)}, {"y", round(y2)}], []}] ++
       label}
  end

  defp new_shape(n, pre) do
    q(
      {:el, "dmndi:DMNShape", [{"id", "dmnshape-drg-#{n.id}"}, {"dmnElementRef", n.id}, {"isCollapsed", "false"}],
       [{:el, "dc:Bounds", [{"x", n.x}, {"y", n.y}, {"width", n.w}, {"height", n.h}], []}]},
      pre
    )
  end

  defp new_edge(m, rid, from, to, pre) do
    {x1, y1, x2, y2} = Svg.endpoints(m, from, to)

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
