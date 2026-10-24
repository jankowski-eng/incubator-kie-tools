defmodule DmnSpike.RoundtripFuzzTest do
  @moduledoc """
  Random edits on real files, then the file is written and read back. Whatever the edits were, the output
  must be a document that holds together: unique ids, every reference pointing at an element that exists,
  nothing lost on a second round trip.
  """
  use ExUnit.Case, async: true

  alias DmnSpike.{Dmn, Model, Types}

  @files ["test/fixtures/Sample.dmn", "test/fixtures/kie_sample.dmn", :sample]
  @seeds 1..150
  @steps 14
  @schema Path.expand("../../../packages/dmn-marshaller/src/schemas/dmn-1_6/DMN16.xsd", __DIR__)

  # Without xmllint the random-edit cases would pass without any schema check, looking the same as a real
  # pass: so its absence fails here, loudly, unless skipping is asked for (DMN_SKIP_SCHEMA=1).
  test "xmllint is installed, so the random-edit documents really are validated against DMN16.xsd" do
    if System.get_env("DMN_SKIP_SCHEMA") == "1" do
      IO.puts(:stderr, "\nDMN_SKIP_SCHEMA=1: the random-edit documents are NOT validated against DMN16.xsd")
    else
      assert System.find_executable("xmllint"),
             "xmllint is not installed: install libxml2 (it ships with macOS) or run with DMN_SKIP_SCHEMA=1 to skip the schema check"
    end
  end

  for file <- @files, seed <- @seeds do
    test "random edits on #{inspect(file)} (seed #{seed}) give a consistent file" do
      :rand.seed(:exsss, {unquote(seed), 42, 7})
      m = load(unquote(file))
      {m, log} = Enum.reduce(1..@steps, {m, []}, fn i, {m, log} -> step(m, i, log) end)
      xml = Dmn.to_xml(m)
      context = "edits: #{inspect(Enum.reverse(log))}"

      check_document!(xml, context)
      check_schema!(xml, context)
      check_roundtrip!(m, xml, context)
    end
  end

  defp load(:sample), do: Model.sample() |> Dmn.to_xml() |> then(&elem(Dmn.from_xml(&1), 1))
  defp load(file), do: file |> File.read!() |> Dmn.from_xml() |> then(&elem(&1, 1))

  # ---- random edits -------------------------------------------------------------------------

  defp pick(list), do: Enum.random(list)
  defp ids(m, fun \\ fn _ -> true end), do: for({id, n} <- m.nodes, fun.(n), do: id) |> Enum.sort()

  defp step(m, i, log) do
    ops = [
      :rename,
      :describe,
      :move,
      :text,
      :table_cell,
      :add_rule,
      :del_rule,
      :add_node,
      :add_required,
      :connect,
      :delete_edge,
      :delete_node,
      :rename_type,
      :expr_kind,
      :set_type,
      :add_group
    ]

    op = pick(ops)

    case apply_op(op, m, i) do
      {:ok, m2, what} -> {m2, [what | log]}
      :skip -> {m, log}
    end
  end

  defp apply_op(:rename, m, i) do
    id = pick(ids(m))
    {:ok, Model.rename(m, id, "Renamed #{i}"), {:rename, id}}
  end

  defp apply_op(:describe, m, i) do
    id = pick(ids(m))
    {:ok, Model.set_description(m, id, "Described #{i} <&>"), {:describe, id}}
  end

  defp apply_op(:move, m, i) do
    id = pick(ids(m))
    {:ok, Model.move(m, id, i * 17, i * 11), {:move, id}}
  end

  defp apply_op(:text, m, i) do
    case ids(m, &(not Model.artifact?(&1) and Model.kind(&1) == :context)) do
      [] ->
        :skip

      list ->
        id = pick(list)
        {:ok, Model.set_text(m, id, 0, "1 + #{i}"), {:text, id}}
    end
  end

  defp apply_op(:table_cell, m, i) do
    case ids(m, &(Model.kind(&1) == :table)) do
      [] ->
        :skip

      list ->
        id = pick(list)
        t = m.nodes[id].expr
        path = if t.rules == [], do: ["h", 0], else: pick([["e", 0, 0], ["o", 0, 0], ["h", 0]])
        path = if path == ["h", 0] and t.inputs == [], do: nil, else: path
        if path, do: {:ok, Model.set_table_text(m, id, path, "#{i}"), {:table_cell, id, path}}, else: :skip
    end
  end

  defp apply_op(:add_rule, m, _i), do: table_op(m, :add_rule, &Model.add_rule(&1, &2))

  defp apply_op(:del_rule, m, _i),
    do: table_op(m, :del_rule, fn m, id -> if m.nodes[id].expr.rules != [], do: Model.del_rule(m, id, 0), else: m end)

  defp apply_op(:add_node, m, i) do
    {m, id} = Model.add_node(m, pick(["decision", "input", "bkm", "annotation", "source"]), i * 40, 500)
    {:ok, m, {:add_node, id}}
  end

  defp apply_op(:add_required, m, _i) do
    id = pick(ids(m, &(&1.type != :group)))
    kind = pick(Model.pad_kinds(m.nodes[id].type) ++ ["none"])

    case kind != "none" && Model.add_required(m, id, kind) do
      {:ok, m2, new} -> {:ok, m2, {:add_required, id, new}}
      _ -> :skip
    end
  end

  defp apply_op(:connect, m, _i) do
    list = ids(m)
    {a, b} = {pick(list), pick(list)}

    case Model.connect(m, a, b) do
      {:ok, m2} -> {:ok, m2, {:connect, a, b}}
      _ -> :skip
    end
  end

  defp apply_op(:delete_edge, m, _i) do
    n = length(Model.edges_all(m))

    if n == 0,
      do: :skip,
      else:
        (
          i = :rand.uniform(n) - 1
          {:ok, Model.delete_edge(m, i), {:delete_edge, i}}
        )
  end

  defp apply_op(:delete_node, m, _i) do
    if map_size(m.nodes) < 4,
      do: :skip,
      else:
        (
          id = pick(ids(m))
          {:ok, Model.delete_node(m, id), {:delete_node, id}}
        )
  end

  defp apply_op(:rename_type, m, i) do
    if m.types == [] do
      :skip
    else
      idx = :rand.uniform(length(m.types)) - 1
      {:ok, Types.rename_top(m, idx, "TypeRenamed#{i}"), {:rename_type, idx}}
    end
  end

  defp apply_op(:expr_kind, m, _i) do
    case ids(m, &(&1.type == :decision and Model.kind(&1) in [:context, :table])) do
      [] ->
        :skip

      list ->
        id = pick(list)
        kind = if Model.kind(m.nodes[id]) == :table, do: :context, else: :table
        {:ok, Model.set_expr_kind(m, id, kind), {:expr_kind, id, kind}}
    end
  end

  defp apply_op(:set_type, m, _i) do
    id = pick(ids(m, &(not Model.artifact?(&1))) ++ [nil])

    if id && m.types != [],
      do: {:ok, Model.set_type_ref(m, id, pick(m.types).name), {:set_type, id}},
      else: :skip
  end

  defp apply_op(:add_group, m, i) do
    {m, id} = Model.add_node(m, "group", i * 50, 300)
    {:ok, m, {:add_group, id}}
  end

  defp table_op(m, name, fun) do
    case ids(m, &(Model.kind(&1) == :table)) do
      [] ->
        :skip

      list ->
        id = pick(list)
        {:ok, fun.(m, id), {name, id}}
    end
  end

  # ---- invariants -------------------------------------------------------------------------

  defp check_document!(xml, context) do
    assert {:ok, root} = Saxy.SimpleForm.parse_string(xml), context
    all = collect(root)
    ids = for {"id", v} <- Enum.flat_map(all, &elem(&1, 1)), do: v
    assert ids == Enum.uniq(ids), "duplicate ids #{inspect(ids -- Enum.uniq(ids))}; " <> context

    idset = MapSet.new(ids)

    refs = for {_, a, _} <- all, {"dmnElementRef", v} <- a, do: v

    assert Enum.all?(refs, &MapSet.member?(idset, &1)),
           "dangling diagram refs #{inspect(Enum.reject(refs, &MapSet.member?(idset, &1)))}; " <> context

    hrefs =
      for {t, a, _} <- all,
          Dmn.local(t) in ~w(requiredInput requiredDecision requiredKnowledge requiredAuthority sourceRef targetRef),
          {"href", "#" <> id} <- a,
          do: id

    assert Enum.all?(hrefs, &MapSet.member?(idset, &1)),
           "dangling requirement refs #{inspect(Enum.reject(hrefs, &MapSet.member?(idset, &1)))}; " <> context

    type_names = for {t, a, _} <- all, Dmn.local(t) == "itemDefinition", {"name", n} <- a, do: n

    used =
      for {t, a, _} <- all,
          Dmn.local(t) in ~w(variable inputExpression output formalParameter),
          {"typeRef", v} <- a,
          do: v

    used = used ++ for {t, _, _} = e <- all, Dmn.local(t) == "typeRef", do: Dmn.text(e)
    custom = Enum.reject(used, &(&1 in Types.builtins() or &1 in [nil, ""]))

    assert Enum.all?(custom, &(&1 in type_names)),
           "unknown type refs #{inspect(Enum.reject(custom, &(&1 in type_names)))}; " <> context
  end

  # Documents in DMN 1.6's namespace are validated against the repository's own DMN16.xsd with xmllint
  # (a file in another namespace, such as the real Sample.dmn, cannot be validated against it).
  defp check_schema!(xml, context) do
    if xmllint = schema_validator() do
      if xml =~ "spec/DMN/20240513/MODEL" do
        file = Path.join(System.tmp_dir!(), "fuzz-#{System.unique_integer([:positive])}.dmn")
        File.write!(file, xml)
        {out, status} = System.cmd(xmllint, ["--noout", "--schema", @schema, file], stderr_to_stdout: true)
        File.rm(file)
        assert status == 0, "not valid against DMN16.xsd:\n#{String.slice(out, 0, 1200)}\n" <> context
      end
    end
  end

  # xmllint, unless validation was switched off on purpose with DMN_SKIP_SCHEMA=1
  defp schema_validator, do: if(System.get_env("DMN_SKIP_SCHEMA") != "1", do: System.find_executable("xmllint"))

  defp collect({_, _, kids} = e), do: [e | Enum.flat_map(Enum.filter(kids, &is_tuple/1), &collect/1)]

  defp check_roundtrip!(m, xml, context) do
    assert {:ok, m2, _} = Dmn.from_xml(xml), context

    # Everything the edits touch, as the model holds it: expressions, table contents, positions, type
    # definitions. Left out on purpose: bookkeeping from the import (a type's origin and committed name) and
    # the values of inputs, which are test data (scenarios) and not part of the file.
    essence = fn m ->
      nodes =
        for {id, n} <- m.nodes do
          # (a business knowledge model without parameters is one with an empty list: the same thing)
          expr =
            case n do
              %{type: :input} -> nil
              %{type: :bkm} -> Map.put_new(n.expr, :params, [])
              _ -> n.expr
            end

          {id, n.type, n.name, Model.description(n), n.type_ref, expr, {n.x, n.y, n.w, n.h}}
        end

      types = for t <- m.types, do: Map.drop(t, [:origin, :committed])
      {Enum.sort(nodes), Enum.sort(m.edges), Enum.sort(m.links), types}
    end

    {n1, e1, l1, t1} = essence.(m)
    {n2, e2, l2, t2} = essence.(m2)

    diff = %{
      nodes: {n1 -- n2, n2 -- n1},
      edges: {e1 -- e2, e2 -- e1},
      links: {l1 -- l2, l2 -- l1},
      types: {t1 -- t2, t2 -- t1}
    }

    assert essence.(m2) == essence.(m), "the model changed on a round trip: #{inspect(diff)}; " <> context
    # a second write of what was just read back gives the same document
    assert canon(Dmn.to_xml(m2)) == canon(xml), "a second round trip changed the document; " <> context
  end

  defp canon(xml) do
    walk = fn walk, {tag, attrs, kids} ->
      kids =
        for k <- kids,
            not (is_binary(k) and String.trim(k) == ""),
            do: if(is_binary(k), do: String.trim(k), else: walk.(walk, k))

      {tag, Enum.sort(attrs), kids}
    end

    xml |> Saxy.SimpleForm.parse_string() |> elem(1) |> then(&walk.(walk, &1))
  end
end
