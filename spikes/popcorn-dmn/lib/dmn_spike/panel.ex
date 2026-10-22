defmodule DmnSpike.Panel do
  @moduledoc "Boxed-expression style table for the selected node."

  alias DmnSpike.{Fmt, Highlight, Model}

  def render(_m, nil, _results), do: ~s|<p class="hint">Click a node to edit its expression.</p>|

  def render(%Model{} = m, id, results) do
    node = m.nodes[id]
    head = head(m, node, results[id])

    body =
      case Model.kind(node) do
        :table -> table(node, results[id])
        :context -> context(node, results[id])
      end

    IO.iodata_to_binary([head, body])
  end

  defp context(node, result) do
    id = node.id
    cells = Model.cells(node) |> Enum.with_index()

    rows =
      for {{label, text}, idx} <- cells do
        r = Enum.at(result.cells, idx)

        [
          ~s|<tr><th class="lbl">#{label_html(label)}</th>|,
          ~s|<td class="expr"><div class="ed"><pre class="hl" id="hl-#{id}-#{idx}">#{hl(text, r)}</pre>|,
          ~s|<textarea data-cell="#{id}:#{idx}" rows="1" spellcheck="false" autocomplete="off">#{Fmt.esc(text)}</textarea>|,
          ~s|<div class="ac" id="ac-#{id}-#{idx}"></div></div></td>|,
          ~s|<td class="val" id="val-#{id}-#{idx}">#{cell_view(r)}</td></tr>|
        ]
      end

    [
      ~s|<table class="boxed"><thead><tr><th colspan="3">#{Fmt.esc(node.name)} <small>#{kind(node)}</small></th></tr></thead><tbody>|,
      rows,
      "</tbody></table>"
    ]
  end

  # --- decision table ----------------------------------------------------------------

  defp table(node, result) do
    t = node.expr
    id = node.id
    n = length(t.inputs)
    errs = result.table.errors

    hp =
      for p <- Model.hit_policies() do
        ~s|<option value="#{p}"#{if p == t.hit_policy, do: " selected"}>#{p}</option>|
      end

    inputs =
      for {inp, i} <- Enum.with_index(t.inputs) do
        ~s|<th class="in">#{dt_ed(id, "h-#{i}", inp.expr, errs)}<button data-click="dt-del-input:#{id}:#{i}" title="Delete input column">✕</button></th>|
      end

    rules =
      for {rule, r} <- Enum.with_index(t.rules) do
        entries = for {e, i} <- Enum.with_index(rule.entries), do: ~s|<td>#{dt_ed(id, "e-#{r}-#{i}", e, errs)}</td>|

        [
          ~s|<tr id="dr-#{id}-#{r}" class="#{rule_class(result, r)}"><td class="rn">#{r + 1}</td>|,
          entries,
          ~s|<td class="out">#{dt_ed(id, "o-#{r}", rule.out, errs)}</td>|,
          ~s|<td class="rm"><button data-click="dt-del-rule:#{id}:#{r}" title="Delete rule">✕</button></td></tr>|
        ]
      end

    IO.iodata_to_binary([
      ~s|<table class="boxed dt"><thead><tr><th class="hp" rowspan="2"><select data-op="dthp" data-id="#{id}" title="Hit policy">#{hp}</select></th>|,
      ~s|<th colspan="#{max(n, 1)}">Input</th><th>Output</th><th rowspan="2"></th></tr>|,
      ~s|<tr>#{inputs}<th>#{Fmt.esc(node.name)}</th></tr></thead><tbody>|,
      rules,
      ~s|</tbody><tfoot><tr><td colspan="#{n + 3}"><button data-click="dt-add-rule:#{id}">+ rule</button> |,
      ~s|<button data-click="dt-add-input:#{id}">+ input</button> <span class="dtv" id="dtv-#{id}">#{table_summary(result)}</span></td></tr></tfoot></table>|
    ])
  end

  defp dt_ed(id, path, text, errs) do
    ~s|<div class="ed"><pre class="hl" id="dhl-#{id}-#{path}">#{Highlight.html(text, err_span(errs[path]))}</pre>| <>
      ~s|<textarea data-op="dtcell" data-id="#{id}" data-path="#{path}" rows="1" spellcheck="false" autocomplete="off">#{Fmt.esc(text)}</textarea></div>|
  end

  defp rule_class(result, r), do: if(Enum.at(result.table.matched, r), do: "rule hit", else: "rule")

  def table_summary(%{value: v, table: %{message: msg}}) do
    "→ <b>#{Fmt.esc(Fmt.value(v))}</b>" <> if(msg, do: ~s| <small class="warn">#{Fmt.esc(msg)}</small>|, else: "")
  end

  @doc "Patches for the live parts of a decision table: matched rows, summary, cell highlights."
  def table_ops(%Model{} = m, id, %{table: tbl} = result) do
    node = m.nodes[id]
    t = node.expr

    rows = for {_, r} <- Enum.with_index(t.rules), do: ["attr", "#dr-#{id}-#{r}", "class", rule_class(result, r)]

    hls =
      [for({inp, i} <- Enum.with_index(t.inputs), do: {"h-#{i}", inp.expr})] ++
        for({rule, r} <- Enum.with_index(t.rules), do: [{"o-#{r}", rule.out} | for({e, i} <- Enum.with_index(rule.entries), do: {"e-#{r}-#{i}", e})])

    hl_ops =
      hls |> List.flatten() |> Enum.map(fn {path, text} -> ["html", "#dhl-#{id}-#{path}", Highlight.html(text, err_span(tbl.errors[path]))] end)

    rows ++ hl_ops ++ [["html", "#dtv-#{id}", table_summary(result)]]
  end

  def table_ops(_m, _id, _result), do: []

  def head(m, node, result) do
    opts =
      for t <- [""] ++ DmnSpike.Types.builtins() ++ Enum.map(m.types, & &1.name) do
        sel = if t == (node.type_ref || ""), do: " selected", else: ""
        ~s|<option value="#{Fmt.esc(t)}"#{sel}>#{if t == "", do: "&lt;Undefined&gt;", else: Fmt.esc(t)}</option>|
      end

    [
      ~s|<div class="nodehead"><input class="nname" data-op="nname" data-id="#{node.id}" value="#{Fmt.esc(node.name)}" spellcheck="false"/>|,
      ~s|<label>type <select data-op="ntype" data-id="#{node.id}">#{opts}</select></label>|,
      ~s|<label>expression <select data-op="nexpr" data-id="#{node.id}"><option value="context"#{if Model.kind(node) == :context, do: " selected"}>literal / context</option><option value="table"#{if Model.kind(node) == :table, do: " selected"}>decision table</option></select></label>|,
      ~s|<span class="errs" id="nerr-#{node.id}">#{errors_html(result)}</span></div>|
    ]
    |> IO.iodata_to_binary()
  end

  def errors_html(nil), do: ""
  def errors_html(%{errors: []}), do: ""
  def errors_html(%{errors: errors}), do: "⚠ " <> Fmt.esc(Enum.join(errors, "; "))

  def hl(text, result), do: Highlight.html(text, err_span(result))

  def cell_view({:ok, v, diags}) do
    note =
      case diags do
        [d | _] -> ~s| <small class="warn" title="#{Fmt.esc(d.message)}">⚠ #{Fmt.esc(d.message)}</small>|
        [] -> ""
      end

    ~s|<span class="v">#{Fmt.esc(Fmt.value(v))}</span>#{note}|
  end

  def cell_view({:error, e}), do: ~s|<span class="bad">#{Fmt.esc(e.message)}</span>|

  defp err_span({:error, %{span: {_, _} = span}}), do: span
  defp err_span(_), do: nil

  defp label_html(:result), do: "«result»"
  defp label_html(name), do: Fmt.esc(name)

  defp kind(%{type: :decision}), do: "decision"
  defp kind(%{type: :bkm}), do: "business knowledge"
  defp kind(%{type: :input}), do: "input data"
end
