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
        errors = DmnSpike.Types.validate(m, node_result.value, m.nodes[id].type_ref)
        Map.put(acc, id, Map.put(node_result, :errors, errors))
    end
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

  def eval(text, env) do
    if String.trim(text) == "", do: {:ok, nil, []}, else: Feel.eval(text, env, sandbox: false)
  end

  def value_of({:ok, v, _}), do: v
  def value_of(_), do: nil
end
