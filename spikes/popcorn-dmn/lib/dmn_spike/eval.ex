defmodule DmnSpike.Eval do
  @moduledoc "Evaluates every node of a model with `feel`, in requirement order."

  alias DmnSpike.Model

  @doc "Returns `%{node_id => %{value: term, cells: [result]}}`."
  def run(%Model{} = m) do
    Enum.reduce(Map.keys(m.nodes), %{}, fn id, acc -> visit(m, id, acc, []) end)
  end

  defp visit(m, id, acc, stack) do
    cond do
      Map.has_key?(acc, id) ->
        acc

      id in stack ->
        acc

      true ->
        deps = for {from, ^id, _} <- m.edges, do: from
        acc = Enum.reduce(deps, acc, &visit(m, &1, &2, [id | stack]))

        env =
          for d <- deps, Map.has_key?(acc, d), into: %{}, do: {m.nodes[d].name, acc[d].value}

        node_result = eval_node(m.nodes[id], env)
        # a business knowledge model's value is a function; its type is the return type
        errors = if m.nodes[id].type == :bkm, do: [], else: DmnSpike.Types.validate(m, node_result.value, m.nodes[id].type_ref)
        Map.put(acc, id, Map.put(node_result, :errors, errors))
    end
  end

  defp eval_node(%{expr: %{kind: :table} = table}, env), do: eval_table(table, env)

  defp eval_node(%{type: :bkm} = node, env) do
    params = Model.params(node)
    # cells are checked with the parameters bound to null, the node's value is the function
    cells = eval_node(%{node | type: :decision}, Enum.reduce(params, env, &Map.put(&2, &1, nil))).cells

    fun =
      case Feel.eval("function(" <> Enum.join(params, ", ") <> ") " <> body_text(node), env, sandbox: false) do
        {:ok, f, _} -> f
        _ -> nil
      end

    %{value: fun, cells: cells}
  end

  defp eval_node(node, env) do
    {cells, _env, last} =
      Enum.reduce(Model.cells(node), {[], env, nil}, fn {label, text}, {acc, env, _} ->
        result = eval(text, env)
        value = value_of(result)
        env = if is_binary(label), do: Map.put(env, label, value), else: env
        {[result | acc], env, value}
      end)

    %{value: last, cells: Enum.reverse(cells)}
  end

  # --- decision tables -------------------------------------------------------------

  defp eval_table(t, env) do
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
        (for {{:error, _} = e, i} <- Enum.with_index(inputs), do: {"h-#{i}", e}) ++
          (for {r, ri} <- Enum.with_index(rules), {{:error, _} = e, i} <- Enum.with_index(r.tests), do: {"e-#{ri}-#{i}", e}) ++
          (for {r, ri} <- Enum.with_index(rules), {{:error, _} = e, k} <- Enum.with_index(r.outs), do: {"o-#{ri}-#{k}", e})
      )

    names = Enum.map(t.outputs, & &1.name)
    matched = for {r, i} <- Enum.with_index(rules), r.matched, do: {i, rule_value(names, Enum.map(r.outs, &value_of/1))}
    {value, message} = hit(t.hit_policy, matched)
    %{value: value, cells: [], table: %{matched: Enum.map(rules, & &1.matched), errors: errors, message: message}}
  end

  # one output column gives its value, several give a context keyed by the output names
  defp rule_value(_names, [value]), do: value
  defp rule_value(names, values), do: names |> Enum.zip(values) |> Map.new()

  defp hit(_, []), do: {nil, "no rule matches"}
  defp hit("UNIQUE", [{_, v}]), do: {v, nil}
  defp hit("UNIQUE", m), do: {nil, "#{length(m)} rules match, UNIQUE allows one"}
  defp hit("FIRST", [{_, v} | _]), do: {v, nil}

  defp hit("ANY", [{_, v} | _] = m),
    do: if(Enum.all?(m, fn {_, x} -> x == v end), do: {v, nil}, else: {nil, "matching rules disagree, ANY needs equal outputs"})

  defp hit(p, m) when p in ["COLLECT", "RULE ORDER"], do: {Enum.map(m, &elem(&1, 1)), nil}
  defp hit(_, _), do: {nil, "unsupported hit policy"}

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
  defp body_text(%{expr: %{rows: [], result: result}}), do: blank_null(result)

  defp body_text(%{expr: %{rows: rows, result: result}}) do
    entries = Enum.map_join(rows, ", ", &"#{&1.name}: #{blank_null(&1.text)}")
    "{#{entries}, __result: #{blank_null(result)}}.__result"
  end

  defp blank_null(text), do: if(String.trim(text) == "", do: "null", else: text)

  def eval(text, env) do
    if String.trim(text) == "", do: {:ok, nil, []}, else: Feel.eval(text, env, sandbox: false)
  end

  def value_of({:ok, v, _}), do: v
  def value_of(_), do: nil
end
