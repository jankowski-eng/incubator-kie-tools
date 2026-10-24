defmodule DmnSpike.Eval do
  @moduledoc "Evaluates every node of a model with `feel`, in requirement order."

  alias DmnSpike.{Model, Types}

  @doc "Returns `%{node_id => %{value: term, cells: [result]}}`."
  def run(%Model{} = m) do
    cyc = cyclic(m)
    Enum.reduce(Map.keys(m.nodes), %{}, fn id, acc -> visit(m, cyc, id, acc, []) end)
  end

  # Nodes that take part in a cycle of requirements (an imported file can have them; the editor refuses to
  # make one). They are not evaluated: with one of its inputs missing, a value would depend on where the
  # evaluation happened to start. Tarjan's algorithm over "requires".
  defp cyclic(m) do
    deps = Enum.group_by(m.edges, fn {_, to, _} -> to end, fn {from, _, _} -> from end)
    st = %{i: 0, idx: %{}, low: %{}, stack: [], on: MapSet.new(), cyc: MapSet.new()}

    m.nodes
    |> Map.keys()
    |> Enum.reduce(st, fn v, st -> if Map.has_key?(st.idx, v), do: st, else: strong(v, deps, st) end)
    |> Map.fetch!(:cyc)
  end

  defp strong(v, deps, st) do
    st = %{
      st
      | idx: Map.put(st.idx, v, st.i),
        low: Map.put(st.low, v, st.i),
        i: st.i + 1,
        stack: [v | st.stack],
        on: MapSet.put(st.on, v)
    }

    st =
      Enum.reduce(Map.get(deps, v, []), st, fn w, st ->
        cond do
          not Map.has_key?(st.idx, w) ->
            st = strong(w, deps, st)
            %{st | low: Map.put(st.low, v, min(st.low[v], st.low[w]))}

          MapSet.member?(st.on, w) ->
            %{st | low: Map.put(st.low, v, min(st.low[v], st.idx[w]))}

          true ->
            st
        end
      end)

    if st.low[v] == st.idx[v] do
      {scc, rest} = pop(st.stack, v, [])

      cyc =
        if length(scc) > 1 or v in Map.get(deps, v, []), do: Enum.reduce(scc, st.cyc, &MapSet.put(&2, &1)), else: st.cyc

      %{st | stack: rest, on: Enum.reduce(scc, st.on, &MapSet.delete(&2, &1)), cyc: cyc}
    else
      st
    end
  end

  defp pop([v | rest], v, acc), do: {[v | acc], rest}
  defp pop([w | rest], v, acc), do: pop(rest, v, [w | acc])

  defp cycle_result(node) do
    base = %{
      value: nil,
      cells: Enum.map(Model.cells(node), fn _ -> {:ok, nil, []} end),
      cycle: true,
      errors: ["part of a dependency cycle, so it is not evaluated"]
    }

    if match?(%{kind: :table}, node.expr),
      do:
        Map.put(base, :table, %{
          matched: Enum.map(node.expr.rules, fn _ -> false end),
          chosen: [],
          errors: %{},
          message: nil
        }),
      else: base
  end

  defp visit(m, cyc, id, acc, stack) do
    cond do
      Map.has_key?(acc, id) ->
        acc

      MapSet.member?(cyc, id) ->
        Map.put(acc, id, cycle_result(m.nodes[id]))

      id in stack ->
        acc

      true ->
        deps = for {from, ^id, _} <- m.edges, do: from
        acc = Enum.reduce(deps, acc, &visit(m, cyc, &1, &2, [id | stack]))

        env =
          for d <- deps, Map.has_key?(acc, d), into: %{}, do: {m.nodes[d].name, acc[d].value}

        node_result = eval_node(m.nodes[id], env, m)
        # a business knowledge model's value is a function; its type is the return type
        errors =
          if m.nodes[id].type == :bkm, do: [], else: DmnSpike.Types.validate(m, node_result.value, m.nodes[id].type_ref)

        # a decision table's columns have types of their own, a business knowledge model may fail to build
        errors = errors ++ Map.get(node_result, :column_errors, [])
        Map.put(acc, id, node_result |> Map.delete(:column_errors) |> Map.put(:errors, errors))
    end
  end

  defp eval_node(%{expr: %{kind: :table} = table}, env, m), do: eval_table(table, env, m)

  # an expression the editor cannot edit yet is kept as it is and not evaluated
  defp eval_node(%{expr: %{kind: :raw}}, _env, _m), do: %{value: nil, cells: []}

  defp eval_node(%{type: :bkm} = node, env, m) do
    params = Model.params(node)
    # cells are checked with the parameters bound to null, the node's value is the function
    cells = eval_node(%{node | type: :decision}, Enum.reduce(params, env, &Map.put(&2, &1, nil)), m).cells

    # a parameter list or body that cannot be built into a function is said so, not turned into a null
    {fun, errors} =
      case Feel.eval("function(" <> Enum.join(params, ", ") <> ") " <> body_text(node), env, sandbox: false) do
        {:ok, f, _} -> {f, []}
        {:error, e} -> {nil, ["cannot build the function: " <> Exception.message(e)]}
      end

    %{value: fun, cells: cells, column_errors: errors}
  end

  defp eval_node(node, env, _m) do
    {cells, _env, last, context} =
      Enum.reduce(Model.cells(node), {[], env, nil, %{}}, fn {label, text}, {acc, env, _, ctx} ->
        result = eval(text, env)
        value = value_of(result)
        {env, ctx} = if is_binary(label), do: {Map.put(env, label, value), Map.put(ctx, label, value)}, else: {env, ctx}
        {[result | acc], env, value, ctx}
      end)

    # a context without a result entry is the context itself, not null
    value = if context_only?(node), do: context, else: last
    %{value: value, cells: Enum.reverse(cells)}
  end

  defp context_only?(%{expr: %{rows: [_ | _], result: result}}), do: String.trim(result) == ""
  # an imported `<context/>`: no entries, no result, and an empty context as the value
  defp context_only?(%{expr: %{rows: [], context: true, result: result}}), do: String.trim(result) == ""
  defp context_only?(_), do: false

  # --- decision tables -------------------------------------------------------------

  defp eval_table(t, env, m) do
    inputs = Enum.map(t.inputs, &eval(&1.expr, env))
    vals = Enum.map(inputs, &value_of/1)
    # names such as `Back End Ratio - 20` only parse correctly when the parser knows the names in scope
    scope = Feel.Scope.new(Map.new(env, fn {name, _} -> {name, :any} end))

    rules =
      for rule <- t.rules do
        tests = for {entry, i} <- Enum.with_index(rule.entries), do: test_entry(entry, Enum.at(vals, i), env, scope)
        %{tests: tests, matched: Enum.all?(tests, &(&1 == {:ok, true})), outs: Enum.map(rule.outs, &eval(&1, env))}
      end

    errors =
      Map.new(
        for({{:error, _} = e, i} <- Enum.with_index(inputs), do: {"h-#{i}", e}) ++
          for(
            {r, ri} <- Enum.with_index(rules),
            {{:error, _} = e, i} <- Enum.with_index(r.tests),
            do: {"e-#{ri}-#{i}", e}
          ) ++
          for(
            {r, ri} <- Enum.with_index(rules),
            {{:error, _} = e, k} <- Enum.with_index(r.outs),
            do: {"o-#{ri}-#{k}", e}
          )
      )

    names = Enum.map(t.outputs, & &1.name)
    matched = for {r, i} <- Enum.with_index(rules), r.matched, do: {i, rule_value(names, Enum.map(r.outs, &value_of/1))}
    # two output columns with one name would silently lose one of the values in the result
    {value, message} =
      case duplicate_names(names) do
        [] ->
          hit(t.hit_policy, matched)

        dups ->
          {nil, "output columns need different names, but #{Enum.map_join(dups, ", ", &name_label/1)} appears twice"}
      end

    # the rules that make up the result: FIRST uses only the earliest match, the other policies every match
    chosen =
      if t.hit_policy == "FIRST",
        do: Enum.take(Enum.map(matched, &elem(&1, 0)), 1),
        else: Enum.map(matched, &elem(&1, 0))

    %{
      value: value,
      cells: [],
      column_errors: column_errors(m, t, vals, rules, chosen),
      table: %{matched: Enum.map(rules, & &1.matched), chosen: chosen, errors: errors, message: message}
    }
  end

  # Each input value against its column's type, and the outputs of the rules that make up the result against
  # the output columns' types (custom types and their constraints resolve through the model).
  defp column_errors(m, t, vals, rules, chosen) do
    inputs =
      for {col, i} <- Enum.with_index(t.inputs),
          ref = typed(col),
          e <- Types.validate(m, Enum.at(vals, i), ref),
          do: "input column #{i + 1}: #{e}"

    outputs =
      for ri <- chosen,
          {col, k} <- Enum.with_index(t.outputs),
          ref = typed(col),
          e <- Types.validate(m, value_of(Enum.at(Enum.at(rules, ri).outs, k)), ref),
          do: "output column #{k + 1}: #{e}"

    Enum.uniq(inputs ++ outputs)
  end

  defp typed(col), do: if(Map.get(col, :type_ref) not in [nil, ""], do: col.type_ref)

  defp duplicate_names(names) when length(names) < 2, do: []

  defp duplicate_names(names),
    do: names |> Enum.frequencies() |> Enum.filter(fn {_, n} -> n > 1 end) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  defp name_label(""), do: "an empty name"
  defp name_label(name), do: "\"#{name}\""

  # one output column gives its value, several give a context keyed by the output names
  defp rule_value(_names, [value]), do: value
  defp rule_value(names, values), do: names |> Enum.zip(values) |> Map.new()

  # a list-valued policy with no match is an empty list, not null
  defp hit(p, []) when p in ["COLLECT", "RULE ORDER"], do: {[], "no rule matches"}
  defp hit(_, []), do: {nil, "no rule matches"}
  defp hit("UNIQUE", [{_, v}]), do: {v, nil}
  defp hit("UNIQUE", m), do: {nil, "#{length(m)} rules match, UNIQUE allows one"}
  defp hit("FIRST", [{_, v} | _]), do: {v, nil}

  defp hit("ANY", [{_, v} | _] = m),
    do:
      if(Enum.all?(m, fn {_, x} -> same?(x, v) end),
        do: {v, nil},
        else: {nil, "matching rules disagree, ANY needs equal outputs"}
      )

  defp hit(p, m) when p in ["COLLECT", "RULE ORDER"], do: {Enum.map(m, &elem(&1, 1)), nil}
  defp hit(_, _), do: {nil, "unsupported hit policy"}

  # FEEL equality: 1 and 1.0 are the same number, also inside lists and contexts
  defp same?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)

  defp same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.zip_with(a, b, &same?/2) |> Enum.all?()

  defp same?(a, b) when is_map(a) and is_map(b) and not is_struct(a) and not is_struct(b),
    do: map_size(a) == map_size(b) and Enum.all?(a, fn {k, x} -> Map.has_key?(b, k) and same?(x, Map.fetch!(b, k)) end)

  defp same?(a, b), do: a == b

  defp test_entry(entry, value, env, scope) do
    if String.trim(entry) in ["", "-"] do
      {:ok, true}
    else
      with {:ok, prepared} <- Feel.prepare(entry, entry: :unary_tests, scope: scope, sandbox: false),
           {:ok, ok?, _} <- Feel.test(prepared, value, env, sandbox: false) do
        {:ok, ok? == true}
      else
        {:error, _} = e -> e
      end
    end
  end

  # a context body becomes `{rows..., __result: result}.__result` so it can sit inside a function
  defp body_text(%{expr: %{rows: [], context: true, result: result}} = n),
    do: if(String.trim(result) == "", do: "{}", else: body_text(put_in(n.expr, Map.delete(n.expr, :context))))

  defp body_text(%{expr: %{rows: [], result: result}}), do: blank_null(result)

  defp body_text(%{expr: %{rows: rows, result: result}}) do
    # every embedded expression ends with a newline, so that a trailing `// comment` cannot swallow the
    # syntax that is put around it
    entries = Enum.map_join(rows, ",", &"#{&1.name}: #{blank_null(&1.text)}\n")
    if String.trim(result) == "", do: "{#{entries}}", else: "{#{entries}, __result: #{result}\n}.__result"
  end

  defp blank_null(text), do: if(String.trim(text) == "", do: "null", else: text)

  def eval(text, env) do
    if String.trim(text) == "", do: {:ok, nil, []}, else: Feel.eval(text, env, sandbox: false)
  end

  def value_of({:ok, v, _}), do: v
  def value_of(_), do: nil
end
