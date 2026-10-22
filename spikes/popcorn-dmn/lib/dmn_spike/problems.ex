defmodule DmnSpike.Problems do
  @moduledoc """
  Everything the editor can tell is wrong or unfinished in a model, in one list: FEEL errors and warnings in
  cells, values that violate their data type, decision tables that match nothing or too much, expressions
  that are still empty, invalid constraints, and elements connected to nothing. The canvas shows the same
  things as a red outline or a tooltip; this is the list a person can work through.
  """

  alias DmnSpike.{Fmt, Model, Types}

  @type problem :: %{
          severity: :error | :warning,
          target: {:node, String.t()} | {:type, non_neg_integer()},
          title: String.t(),
          message: String.t()
        }

  @doc "Problems of `model` given the evaluation `results`, errors first, then by name."
  def list(%Model{} = m, results) do
    node_problems =
      for {id, node} <- m.nodes, not Model.artifact?(node), p <- of_node(m, node, results[id], results), do: p

    (node_problems ++ type_problems(m.types))
    |> Enum.sort_by(&{&1.severity != :error, String.downcase(&1.title), &1.message})
  end

  defp of_node(m, node, result, results) do
    target = {:node, node.id}
    mk = fn severity, message -> %{severity: severity, target: target, title: node.name, message: message} end

    cell_problems(node, result, mk, upstream_null?(m, node, results)) ++
      for(e <- (result && result.errors) || [], do: mk.(:error, "value does not fit its type: " <> e)) ++
      table_problems(node, result, mk) ++ empty_problems(node, mk) ++ isolated_problems(m, node, mk)
  end

  # An operand that is null because something it needs is null (or failed) is the symptom, not the problem,
  # so those warnings are left out while an upstream value is missing.
  defp upstream_null?(m, node, results) do
    Enum.any?(m.edges, fn {from, to, _} -> to == node.id and match?(%{value: nil}, results[from]) end)
  end

  # FEEL errors and warnings in the cells of a context or literal
  defp cell_problems(node, %{cells: cells}, mk, quiet?) when cells != [] do
    labels = Model.cells(node)
    # after an error in this node, a null further down is its consequence
    # (and a business knowledge model's cells are checked with its parameters bound to null)
    quiet? = quiet? or node.type == :bkm or Enum.any?(cells, &match?({:error, _}, &1))

    for {cell, i} <- Enum.with_index(cells),
        p <- cell_problem(cell, label(Enum.at(labels, i)), mk, quiet?),
        do: p
  end

  defp cell_problems(_node, _result, _mk, _quiet?), do: []

  defp cell_problem({:error, e}, where, mk, _), do: [mk.(:error, "#{where}: #{e.message}")]

  defp cell_problem({:ok, _, diags}, where, mk, quiet?) do
    for d <- diags, not (quiet? and d.message =~ ~r/null/i), do: mk.(:warning, "#{where}: #{d.message}")
  end

  defp cell_problem(_, _, _, _), do: []

  defp label({:result, _}), do: "result"
  defp label({name, _}), do: name
  defp label(nil), do: "cell"

  # errors in a decision table's cells, and what it did with the input
  defp table_problems(%{expr: %{kind: :table}}, %{table: %{errors: errors, message: message}}, mk) do
    cells =
      for {path, {:error, e}} <- Enum.sort(errors), do: mk.(:error, "#{table_where(path)}: #{e.message}")

    summary =
      case message do
        nil -> []
        "no rule matches" -> [mk.(:warning, "no rule matches the current input")]
        other -> [mk.(:error, other)]
      end

    cells ++ summary
  end

  defp table_problems(_node, _result, _mk), do: []

  defp table_where("h-" <> i), do: "input column #{num(i)}"

  defp table_where("e-" <> rest) do
    [r, i] = String.split(rest, "-")
    "rule #{num(r)}, input #{num(i)}"
  end

  defp table_where("o-" <> rest) do
    [r, k] = String.split(rest, "-")
    "rule #{num(r)}, output #{num(k)}"
  end

  defp table_where(other), do: other
  defp num(s), do: String.to_integer(s) + 1

  # a decision or business knowledge model with nothing in it
  defp empty_problems(%{type: type, expr: expr} = node, mk) when type in [:decision, :bkm] do
    case Model.kind(node) do
      :context ->
        if Enum.all?(Model.cells(node), fn {_, text} -> String.trim(text) == "" end),
          do: [mk.(:warning, "has no expression yet")],
          else: []

      :table ->
        if expr.rules == [], do: [mk.(:warning, "the decision table has no rules")], else: []

      _ ->
        []
    end
  end

  defp empty_problems(_node, _mk), do: []

  defp isolated_problems(m, node, mk) do
    drg = Enum.count(m.nodes, fn {_, n} -> not Model.artifact?(n) end)
    touches? = Enum.any?(Model.edges_all(m), fn {a, b, _} -> node.id in [a, b] end)

    if drg > 1 and not touches?, do: [mk.(:warning, "is not connected to anything")], else: []
  end

  # invalid constraint text on a data type or one of its components
  defp type_problems(types) do
    types
    |> Enum.with_index()
    |> Enum.flat_map(fn {t, i} -> type_problem(t, i, t.name, t.name) end)
  end

  defp type_problem(t, i, top, path) do
    own =
      case Types.constraint_error(t.constraint) do
        nil ->
          []

        err ->
          [%{severity: :error, target: {:type, i}, title: top, message: "#{path}: invalid constraint: #{err.message}"}]
      end

    own ++ Enum.flat_map(t.components, &type_problem(&1, i, top, path <> "." <> &1.name))
  end

  @doc "The list as HTML for the popover; `limit` entries at most."
  def html([], _limit), do: ~s|<p class="none">Nothing to fix.</p>|

  def html(problems, limit) do
    shown = Enum.take(problems, limit)

    rows =
      for p <- shown do
        action =
          case p.target do
            {:node, id} -> "problem-node:" <> id
            {:type, i} -> "problem-type:#{i}"
          end

        ~s|<li><button class="problem #{p.severity}" data-click="#{Fmt.esc(action)}"><b>#{Fmt.esc(p.title)}</b><span>#{Fmt.esc(p.message)}</span></button></li>|
      end

    more = length(problems) - length(shown)
    more = if more > 0, do: ~s|<li class="none">and #{more} more</li>|, else: ""
    "<ul>" <> Enum.join(rows) <> more <> "</ul>"
  end

  @doc "The button label: a tick, or the number of problems (errors counted separately when there are any)."
  def summary(problems) do
    errors = Enum.count(problems, &(&1.severity == :error))

    cond do
      problems == [] ->
        {"✓ No problems", "ok"}

      errors > 0 ->
        {"⚠ #{length(problems)} problem#{if length(problems) > 1, do: "s"} (#{errors} error#{if errors > 1, do: "s"})",
         "bad"}

      true ->
        {"⚠ #{length(problems)} warning#{if length(problems) > 1, do: "s"}", "warn"}
    end
  end
end
