defmodule DmnSpike.XmlIndex do
  @moduledoc """
  Where each element of the editor is in the XML text, for the XML inspector.

  The document is the one `Dmn.to_xml/2` writes (fresh, or an imported file written back by `Dmn.Overlay`), walked
  once more as lines (`Dmn.render_lines/3`). Elements are tied to the model by the ids they carry, never by name
  alone, and each range is the lines of its element:

    * `{:node, id}` - `decision`, `inputData`, `businessKnowledgeModel`, `knowledgeSource`, `textAnnotation`, `group`
      whose `id` is a node of the model, and the diagram shape that points at it
    * `{:edge, from, to}` - an information, knowledge or authority requirement (inside the element that requires),
      an association, and the diagram edge that points at either
    * `{:type, path}` - an `itemDefinition` / `itemComponent`, as a path of indexes through the model's types

  Elements without a visual counterpart (the variable, the expression, the namespace declarations) have no key:
  a click inside them belongs to the nearest enclosing range, which is how a line is resolved to a selection.
  """

  alias DmnSpike.{Dmn, Model, Types}

  @node_tags ~w(decision inputData businessKnowledgeModel knowledgeSource textAnnotation group)
  @requirements ~w(informationRequirement knowledgeRequirement authorityRequirement)

  @doc """
  `%{text, lines, ranges, folds}`: the document, its lines, `{from, to, key}` for what has a counterpart in the
  editor (in the order their elements end, so an element comes before the diagram that shows it) and `{from, to}`
  of every element that spans several lines.
  """
  def build(%Model{} = m, name \\ "Popcorn spike") do
    {header, root} = Dmn.document(m, name)
    head_lines = header |> String.trim_trailing("\n") |> String.split("\n")
    {body, spans, _} = Dmn.render_lines(root, 0, length(head_lines) + 1)
    lines = head_lines ++ body

    %{
      text: Enum.join(lines, "\n") <> "\n",
      lines: lines,
      ranges: ranges(spans, m),
      folds: for({from, to, _, _} <- spans, to > from, do: {from, to})
    }
  end

  defp ranges(spans, m) do
    types = type_paths(spans, m)

    # the first pass keys what the model has by id; the diagram refers to those ids
    {keyed, ids} =
      Enum.map_reduce(spans, %{}, fn {from, _to, el, parent}, ids ->
        key = key(el, parent, m) || if(path = types[from], do: {:type, path})
        {key, if(key, do: put_id(ids, el, key), else: ids)}
      end)

    for {{from, to, {:el, tag, attrs, _}, _}, key} <- Enum.zip(spans, keyed),
        key = key || diagram_key(Dmn.local(tag), attrs, ids),
        do: {from, to, key}
  end

  defp put_id(ids, {:el, _, attrs, _}, key), do: if(id = Dmn.attr(attrs, "id"), do: Map.put(ids, id, key), else: ids)

  defp key({:el, tag, attrs, kids}, parent, m) do
    case Dmn.local(tag) do
      t when t in @node_tags -> if m.nodes[Dmn.attr(attrs, "id")], do: {:node, Dmn.attr(attrs, "id")}
      t when t in @requirements -> requirement(kids, parent, m)
      "association" -> association(kids, m)
      _ -> nil
    end
  end

  # a requirement belongs to the element that contains it and points at what it requires
  defp requirement(kids, {_, {:el, _, pattrs, _}}, m) do
    to = Dmn.attr(pattrs, "id")
    from = Enum.find_value(kids, fn {:el, _, a, _} -> href(a) end)
    if from && m.nodes[from] && m.nodes[to], do: {:edge, from, to}
  end

  defp requirement(_kids, _parent, _m), do: nil

  defp association(kids, m) do
    ref = fn name -> Enum.find_value(kids, fn {:el, t, a, _} -> if Dmn.local(t) == name, do: href(a) end) end

    case Dmn.link_key(m.nodes, ref.("sourceRef"), ref.("targetRef")) do
      {from, to, :association} -> {:edge, from, to}
      nil -> nil
    end
  end

  defp href(attrs), do: if(h = Dmn.attr(attrs, "href"), do: h |> to_string() |> String.split("#") |> List.last())

  # the diagram's shapes and edges point at an element by id
  defp diagram_key(tag, attrs, ids) when tag in ["DMNShape", "DMNEdge"], do: ids[Dmn.attr(attrs, "dmnElementRef")]
  defp diagram_key(_tag, _attrs, _ids), do: nil

  # --- data types: by name, so the order the writer used does not matter -------------------------

  # `%{first line => path}` for itemDefinitions and itemComponents, found by walking them against the model's types:
  # the nth element called X is the nth type (or field) called X
  defp type_paths(spans, m) do
    spans
    |> Enum.filter(fn {_, _, {:el, tag, _, _}, _} -> Dmn.local(tag) in ["itemDefinition", "itemComponent"] end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, %{}}, fn {from, _, {:el, tag, attrs, _}, parent}, {paths, seen} ->
      name = Dmn.attr(attrs, "name")
      {owner, items} = owner(Dmn.local(tag), parent, paths, m)
      nth = Map.get(seen, {owner, name}, 0)
      seen = Map.put(seen, {owner, name}, nth + 1)

      case items && nth_index(items, name, nth) do
        i when is_integer(i) -> {Map.put(paths, from, base(owner, paths) ++ [i]), seen}
        _ -> {paths, seen}
      end
    end)
    |> elem(0)
  end

  # what an item definition or component is counted among: the model's types, or the components of its parent type
  defp owner("itemDefinition", _parent, _paths, m), do: {:top, m.types}

  defp owner(_, {pfrom, _}, paths, m) do
    case paths[pfrom] && Types.fetch(m.types, paths[pfrom]) do
      %{components: cs} -> {pfrom, cs}
      _ -> {pfrom, nil}
    end
  end

  defp owner(_, nil, _paths, _m), do: {nil, nil}

  defp base(:top, _paths), do: []
  defp base(pfrom, paths), do: paths[pfrom]

  # the index of the nth item called `name`
  defp nth_index(items, name, nth) do
    case items |> Enum.with_index() |> Enum.filter(fn {t, _} -> t.name == name end) |> Enum.at(nth) do
      {_, i} -> i
      nil -> nil
    end
  end
end
