defmodule DmnSpike.Panel do
  @moduledoc "Boxed-expression style table for the selected node."

  alias DmnSpike.{Fmt, Highlight, Model}

  def render(_m, nil, _results), do: ~s|<p class="hint">Click a node to edit its expression.</p>|

  def render(%Model{} = m, id, results) do
    node = m.nodes[id]
    head = head(m, node, results[id])
    cells = Model.cells(node) |> Enum.with_index()

    rows =
      for {{label, text}, idx} <- cells do
        result = Enum.at(results[id].cells, idx)

        [
          ~s|<tr><th class="lbl">#{label_html(label)}</th>|,
          ~s|<td class="expr"><div class="ed"><pre class="hl" id="hl-#{id}-#{idx}">#{hl(text, result)}</pre>|,
          ~s|<textarea data-cell="#{id}:#{idx}" rows="1" spellcheck="false" autocomplete="off">#{Fmt.esc(text)}</textarea>|,
          ~s|<div class="ac" id="ac-#{id}-#{idx}"></div></div></td>|,
          ~s|<td class="val" id="val-#{id}-#{idx}">#{cell_view(result)}</td></tr>|
        ]
      end

    IO.iodata_to_binary([
      head,
      ~s|<table class="boxed"><thead><tr><th colspan="3">#{Fmt.esc(node.name)} <small>#{kind(node)}</small></th></tr></thead><tbody>|,
      rows,
      "</tbody></table>"
    ])
  end

  def head(m, node, result) do
    opts =
      for t <- [""] ++ DmnSpike.Types.builtins() ++ Enum.map(m.types, & &1.name) do
        sel = if t == (node.type_ref || ""), do: " selected", else: ""
        ~s|<option value="#{Fmt.esc(t)}"#{sel}>#{if t == "", do: "&lt;Undefined&gt;", else: Fmt.esc(t)}</option>|
      end

    [
      ~s|<div class="nodehead"><input class="nname" data-op="nname" data-id="#{node.id}" value="#{Fmt.esc(node.name)}" spellcheck="false"/>|,
      ~s|<label>type <select data-op="ntype" data-id="#{node.id}">#{opts}</select></label>|,
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
