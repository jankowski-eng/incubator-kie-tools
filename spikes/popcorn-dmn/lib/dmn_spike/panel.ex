defmodule DmnSpike.Panel do
  @moduledoc "Boxed-expression style table for the selected node."

  alias DmnSpike.{Fmt, Highlight, Model}

  def render(m, id, results, dock \\ "expr")

  # nothing selected: the panel is empty and hidden (`#panel:empty`)
  def render(_m, nil, _results, _dock), do: ""

  def render(%Model{} = m, id, results, dock) do
    node = m.nodes[id]
    if Model.artifact?(node), do: artifact(m, node), else: render_drg(m, node, results, dock)
  end

  # annotations (and later sources and groups): a text field, no expression
  defp artifact(m, %{type: :annotation} = node) do
    linked = Model.links_of(m, node.id)

    ~s|<div class="props single"><label class="desc">Annotation text<textarea class="nname" data-op="nname" data-id="#{node.id}" rows="4" placeholder="Write a note about this diagram" spellcheck="true">#{Fmt.esc(node.name)}</textarea></label>| <>
      ~s|<dl><dt>Describes</dt><dd>#{chips(linked, "No element yet. Drag from the blue handle to one.")}</dd></dl></div>|
  end

  defp artifact(m, %{type: :group} = node) do
    inside = for k <- Model.members(m, node.id), n = m.nodes[k], do: {n.id, n.name, "member"}

    ~s|<div class="props"><div class="srchead"><label class="desc">Group name<input class="nname" data-op="nname" data-id="#{node.id}" value="#{Fmt.esc(node.name)}" spellcheck="false"/></label></div>| <>
      ~s|<dl><dt>Contains</dt><dd>#{chips(inside, "Nothing yet. Drag elements into the frame.")}</dd></dl></div>|
  end

  defp artifact(m, %{type: :source} = node) do
    {from, to} = Model.authorities(m, node.id)

    ~s|<div class="props"><div class="srchead"><label class="desc">Name<input class="nname" data-op="nname" data-id="#{node.id}" value="#{Fmt.esc(node.name)}" spellcheck="false"/></label>| <>
      ~s|<label class="desc">Description<textarea data-op="ndesc" data-id="#{node.id}" rows="4" placeholder="Where does this authority come from?" spellcheck="true">#{Fmt.esc(Model.description(node))}</textarea></label></div>| <>
      ~s|<dl><dt>Kind</dt><dd>knowledge source</dd><dt>ID</dt><dd><code>#{Fmt.esc(node.id)}</code></dd>| <>
      ~s|<dt>Takes authority from</dt><dd>#{chips(from, "none")}</dd><dt>Authority for</dt><dd>#{chips(to, "none")}</dd></dl></div>|
  end

  defp chips([], none), do: ~s|<span class="none">#{none}</span>|

  defp chips(list, _none),
    do:
      Enum.map_join(
        list,
        " ",
        fn {id, name, kind} ->
          ~s|<button class="chip #{kind}" data-click="goto:#{id}" title="#{kind}">#{Fmt.esc(name)}</button>|
        end
      )

  defp render_drg(%Model{} = m, node, results, dock) do
    id = node.id

    body =
      cond do
        dock == "props" ->
          props(m, node)

        true ->
          case Model.kind(node) do
            :table -> table(m, node, results[id])
            :context -> context(m, node, results[id])
            :raw -> raw(node)
          end
      end

    IO.iodata_to_binary([head(m, node, results[id]), tabs(dock), body])
  end

  defp tabs(dock) do
    btn = fn id, label ->
      ~s|<button data-click="dock:#{id}" aria-pressed="#{dock == id}">#{label}</button>|
    end

    ~s|<div class="dtabs" role="group" aria-label="Inspector">#{btn.("expr", "Expression")}#{btn.("props", "Properties")}</div>|
  end

  # description, identity and how the node is wired
  defp props(m, node) do
    {requires, required_by} = Model.neighbours(m, node.id)

    chips = &chips(&1, "none")
    linked = Model.links_of(m, node.id)

    [
      ~s|<div class="props"><label class="desc">Description<textarea data-op="ndesc" data-id="#{node.id}" rows="4" placeholder="What is this #{kind(node)} for?" spellcheck="true">#{Fmt.esc(Model.description(node))}</textarea></label>|,
      ~s|<dl><dt>Kind</dt><dd>#{kind(node)}</dd><dt>ID</dt><dd><code>#{Fmt.esc(node.id)}</code></dd>|,
      ~s|<dt>Requires</dt><dd>#{chips.(requires)}</dd><dt>Required by</dt><dd>#{chips.(required_by)}</dd>#{if linked != [], do: "<dt>Linked</dt><dd>#{chips.(linked)}</dd>"}</dl></div>|
    ]
  end

  # an expression kind the editor cannot edit yet: shown, written back exactly as in the file
  defp raw(node) do
    [
      ~s|<p class="hint">This expression is a <b>#{Fmt.esc(node.expr.tag)}</b>. The editor cannot edit it yet, so it is kept exactly as it is in the file. |,
      ~s|Choose another expression type above to replace it.</p>|
    ]
  end

  defp context(m, node, result) do
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
      ~s|<table class="boxed"><thead><tr><th colspan="3">#{Fmt.esc(node.name)} <small>#{kind(node)}#{scenario_hint(m, node)}</small></th></tr></thead><tbody>|,
      rows,
      "</tbody></table>"
    ]
  end

  # an input's value is test data: it belongs to the current scenario, not to the file
  defp scenario_hint(m, %{type: :input}), do: " · value in “#{Fmt.esc(Enum.at(Model.scenarios(m), m.scenario).name)}”"
  defp scenario_hint(_m, _node), do: ""

  # --- decision table ----------------------------------------------------------------

  # a zero-width space keeps an empty (or newline-ending) mirror line as tall as a text line
  @zwsp "\u200b"

  defp table(m, node, result) do
    t = node.expr
    id = node.id
    n = length(t.inputs)
    k = length(t.outputs)
    ni = max(n, 1)
    errs = result.table.errors

    hp =
      for p <- Model.hit_policies() do
        ~s|<option value="#{p}"#{if p == t.hit_policy, do: " selected"}>#{p}</option>|
      end

    inputs =
      if n == 0 do
        [~s|<th class="in empty"><button data-click="dt-ins-input:#{id}:0">+ Add input</button></th>|]
      else
        for {inp, i} <- Enum.with_index(t.inputs) do
          [
            ~s|<th class="in">|,
            col_actions("input", id, i, true),
            dt_ed(id, "h-#{i}", inp.expr, errs),
            type_select(m, id, "h-#{i}", Map.get(inp, :type_ref)),
            "</th>"
          ]
        end
      end

    outputs =
      for {o, j} <- Enum.with_index(t.outputs) do
        name =
          if k == 1, do: ~s|<div class="outname">#{Fmt.esc(node.name)}</div>|, else: dt_ed(id, "n-#{j}", o.name, errs)

        [
          ~s|<th class="outh">|,
          col_actions("output", id, j, k > 1),
          name,
          type_select(m, id, "n-#{j}", Map.get(o, :type_ref)),
          "</th>"
        ]
      end

    rules =
      for {rule, r} <- Enum.with_index(t.rules) do
        entries =
          if n == 0,
            do: [~s|<td class="empty"></td>|],
            else: for({e, i} <- Enum.with_index(rule.entries), do: ~s|<td>#{dt_ed(id, "e-#{r}-#{i}", e, errs)}</td>|)

        outs =
          for {o, j} <- Enum.with_index(rule.outs), do: ~s|<td class="out">#{dt_ed(id, "o-#{r}-#{j}", o, errs)}</td>|

        note = Map.get(rule, :note, "")

        [
          ~s|<tr id="dr-#{id}-#{r}" class="#{rule_class(result, r)}"><td class="rn">#{r + 1}|,
          ~s|<button class="ins up rowact" data-click="dt-ins-rule:#{id}:#{r}" title="Insert rule above" aria-label="Insert rule above">+</button>|,
          ~s|<button class="ins down rowact" data-click="dt-ins-rule:#{id}:#{r + 1}" title="Insert rule below" aria-label="Insert rule below">+</button></td>|,
          entries,
          outs,
          ~s|<td class="note"><div class="ed"><pre class="hl" id="note-#{id}-#{r}">#{Fmt.esc(note)}#{@zwsp}</pre>|,
          ~s|<textarea data-op="dtnote" data-id="#{id}" data-path="#{r}" rows="1" spellcheck="false" autocomplete="off">#{Fmt.esc(note)}</textarea></div></td>|,
          ~s|<td class="rm"><button class="del rowact" data-click="dt-del-rule:#{id}:#{r}" title="Delete rule" aria-label="Delete rule">✕</button></td></tr>|
        ]
      end

    no_rules =
      if t.rules == [],
        do: [
          ~s|<tr><td class="norules" colspan="#{ni + k + 3}"><button data-click="dt-ins-rule:#{id}:0">+ Add rule</button></td></tr>|
        ],
        else: []

    IO.iodata_to_binary([
      ~s|<table class="boxed dt"><thead><tr><th class="hp" rowspan="2"><select data-op="dthp" data-id="#{id}" title="Hit policy">#{hp}</select></th>|,
      ~s|<th colspan="#{ni}">Input</th><th colspan="#{k}">Output</th><th rowspan="2" class="noteh">#{Fmt.esc(Map.get(t, :note_title) || "Annotation")}</th><th rowspan="2"></th></tr>|,
      ~s|<tr>#{inputs}#{outputs}</tr></thead><tbody>|,
      rules,
      no_rules,
      ~s|</tbody><tfoot><tr><td colspan="#{ni + k + 3}"><span class="dtv" id="dtv-#{id}">#{table_summary(result)}</span></td></tr></tfoot></table>|
    ])
  end

  # insert-left/right circles on the header's borders and a delete button in its corner; CSS shows them on hover
  defp col_actions(kind, id, i, deletable?) do
    [
      ~s|<button class="ins left colact" data-click="dt-ins-#{kind}:#{id}:#{i}" title="Insert #{kind} on the left" aria-label="Insert #{kind} on the left">+</button>|,
      ~s|<button class="ins right colact" data-click="dt-ins-#{kind}:#{id}:#{i + 1}" title="Insert #{kind} on the right" aria-label="Insert #{kind} on the right">+</button>|,
      if(deletable?,
        do:
          ~s|<button class="del colact" data-click="dt-del-#{kind}:#{id}:#{i}" title="Delete #{kind} column" aria-label="Delete #{kind} column">✕</button>|,
        else: ""
      )
    ]
  end

  defp type_select(m, id, path, current),
    do:
      ~s|<select class="coltype" data-op="dttype" data-id="#{id}" data-path="#{path}" title="Type">#{type_options(m, current)}</select>|

  @doc """
  The options of a type reference select: the types and their `T!` and `list<T>` forms, grouped. A reference that
  is not among them (a type that does not exist, or a form written in a file) stays selectable, as the file has it.
  Options: `:first` the `{value, label}` of the empty choice, `:hide` the names that cannot be chosen.
  """
  def type_options(%Model{} = m, current, opts \\ []) do
    {empty, label} = Keyword.get(opts, :first, {"", "<Undefined>"})
    cur = current || ""
    groups = DmnSpike.Types.choices(m, Keyword.get(opts, :hide, []))
    listed = [empty | Enum.flat_map(groups, &elem(&1, 1))]
    opt = fn v, text -> ~s|<option value="#{Fmt.esc(v)}"#{if v == cur, do: " selected"}>#{Fmt.esc(text)}</option>| end

    IO.iodata_to_binary([
      opt.(empty, label),
      if(cur in listed, do: "", else: opt.(cur, cur)),
      for(
        {group, refs} <- groups,
        refs != [],
        do: ~s|<optgroup label="#{group}">#{Enum.map(refs, &opt.(&1, &1))}</optgroup>|
      )
    ])
  end

  defp dt_ed(id, path, text, errs) do
    ~s|<div class="ed"><pre class="hl" id="dhl-#{id}-#{path}">#{Highlight.html(text, err_span(errs[path]))}</pre>| <>
      ~s|<textarea data-op="dtcell" data-id="#{id}" data-path="#{path}" rows="1" spellcheck="false" autocomplete="off">#{Fmt.esc(text)}</textarea></div>|
  end

  # "hit": the rule makes up the result; "also": it matches, but the hit policy (FIRST) ignores it
  defp rule_class(%{table: t}, r) do
    cond do
      r in t.chosen -> "rule hit"
      Enum.at(t.matched, r) -> "rule also"
      true -> "rule"
    end
  end

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
        [if(length(t.outputs) > 1, do: for({o, j} <- Enum.with_index(t.outputs), do: {"n-#{j}", o.name}), else: [])] ++
        for(
          {rule, r} <- Enum.with_index(t.rules),
          do:
            for({o, j} <- Enum.with_index(rule.outs), do: {"o-#{r}-#{j}", o}) ++
              for({e, i} <- Enum.with_index(rule.entries), do: {"e-#{r}-#{i}", e})
        )

    hl_ops =
      hls
      |> List.flatten()
      |> Enum.map(fn {path, text} ->
        ["html", "#dhl-#{id}-#{path}", Highlight.html(text, err_span(tbl.errors[path]))]
      end)

    rows ++ hl_ops ++ [["html", "#dtv-#{id}", table_summary(result)]]
  end

  def table_ops(_m, _id, _result), do: []

  def head(m, node, result) do
    opts = type_options(m, node.type_ref)

    [
      ~s|<div class="nodehead"><input class="nname" data-op="nname" data-id="#{node.id}" value="#{Fmt.esc(node.name)}" spellcheck="false"/>|,
      ~s|<label>type <select data-op="ntype" data-id="#{node.id}">#{opts}</select></label>|,
      if(node.type == :bkm,
        do:
          ~s|<label>parameters <input class="params" data-op="nparams" data-id="#{node.id}" value="#{Fmt.esc(Enum.join(Model.params(node), ", "))}" placeholder="none" spellcheck="false"/></label>|,
        else: ""
      ),
      # input data is just a name, a type and a value: there is no expression to choose
      if(node.type == :input,
        do: "",
        else:
          ~s|<label>expression <select data-op="nexpr" data-id="#{node.id}"><option value="context"#{if Model.kind(node) == :context, do: " selected"}>literal / context</option>#{if node.type == :decision, do: ~s|<option value="table"#{if Model.kind(node) == :table, do: " selected"}>decision table</option>|}#{if Model.kind(node) == :raw, do: ~s|<option value="raw" selected disabled>#{Fmt.esc(node.expr.tag)} (kept, read-only)</option>|}</select></label>|
      ),
      ~s|<span class="errs" id="nerr-#{node.id}">#{errors_html(result)}</span>|,
      ~s|<button class="close" data-click="deselect" title="Close (Esc)" aria-label="Close">✕</button></div>|
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
