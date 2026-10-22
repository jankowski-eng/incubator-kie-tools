defmodule DmnSpike.TypesPanel do
  @moduledoc """
  The Data types tab: a tree of item definitions on the left and a properties inspector on the right.

  The tree and the inspector are patched separately (`#ttree`, `#tinspector`) so the tree keeps keyboard focus
  while the selection changes. `ui` is the view state kept by the editor:

      %{sel: "0-1" | nil, closed: MapSet of path strings, q: search text,
        insp: inspector open?, edit: nil | {path, :name | :type}, adv: MapSet of paths edited as raw FEEL}
  """

  alias DmnSpike.{Constraint, Fmt, Highlight, Model, Types}

  @ops [{"<", "<"}, {"<=", "≤"}, {">", ">"}, {">=", "≥"}]
  @modes [none: "None", cmp: "Compare", interval: "Interval", list: "Values", feel: "FEEL"]

  def path_str(path), do: Enum.join(path, "-")
  def parse_path(p), do: p |> String.split("-", trim: true) |> Enum.map(&String.to_integer/1)

  @doc "The selected path as a list, or nil when nothing is selected or the path no longer exists."
  def sel_path(%Model{} = m, %{sel: sel}) when is_binary(sel) do
    path = parse_path(sel)
    if Types.fetch(m.types, path), do: path
  end

  def sel_path(_m, _ui), do: nil

  # --- whole tab -----------------------------------------------------------------------

  def render(%Model{} = m, ui) do
    IO.iodata_to_binary([
      ~s|<div id="tview" data-inspector="#{if ui.insp, do: "open", else: "closed"}">|,
      ~s|<div class="ttoolbar"><input type="search" data-op="tsearch" placeholder="Search types and fields" value="#{Fmt.esc(ui.q)}" aria-label="Search types and fields" spellcheck="false"/>|,
      ~s|<button data-click="add-type">+ Add data type</button>|,
      ~s|<span class="grow"></span><button class="tb" data-click="tinsp-toggle" aria-pressed="#{ui.insp}">Properties</button></div>|,
      ~s|<div class="tlayout"><div id="ttree" tabindex="0" role="tree" aria-label="Data types">#{tree(m, ui)}</div>|,
      ~s|<aside id="tinspector" aria-label="Properties">#{inspector(m, ui)}</aside></div></div>|
    ])
  end

  # --- tree ------------------------------------------------------------------------------

  @doc "The rows that are on screen, in order: `[{path, depth, type}]`."
  def visible(%Model{} = m, ui) do
    q = String.downcase(String.trim(ui.q))
    m.types |> Enum.with_index() |> Enum.flat_map(fn {t, i} -> walk(t, [i], 0, ui, q) end)
  end

  defp walk(t, path, depth, ui, q) do
    if q != "" and not included?(t, q) do
      []
    else
      kids =
        if open?(t, path, ui, q),
          do:
            t.components |> Enum.with_index() |> Enum.flat_map(fn {c, i} -> walk(c, path ++ [i], depth + 1, ui, q) end),
          else: []

      [{path, depth, t} | kids]
    end
  end

  # in a search the ancestors of a match are shown open; otherwise the user's choice counts
  defp open?(%{components: []}, _path, _ui, _q), do: false
  defp open?(t, _path, _ui, q) when q != "", do: Enum.any?(t.components, &included?(&1, q))
  defp open?(_t, path, ui, _q), do: not MapSet.member?(ui.closed, path_str(path))

  defp included?(t, q), do: matches?(t, q) or Enum.any?(t.components, &included?(&1, q))

  defp matches?(t, q) do
    hay = [t.name, t.ref || "structure", t.constraint && t.constraint.text]
    Enum.any?(hay, &(is_binary(&1) and String.contains?(String.downcase(&1), q)))
  end

  def tree(%Model{types: []}, _ui),
    do: ~s|<p class="hint">No data types yet.</p>|

  def tree(%Model{} = m, ui) do
    rows = visible(m, ui)
    q = String.downcase(String.trim(ui.q))

    body =
      if rows == [],
        do: [~s|<p class="hint">Nothing matches “#{Fmt.esc(ui.q)}”.</p>|],
        else: Enum.map(rows, &row(m, ui, &1, q))

    IO.iodata_to_binary([
      ~s|<div class="thead" aria-hidden="true"><span>Name</span><span>Type</span><span>Constraint</span><span></span></div>|,
      body
    ])
  end

  defp row(m, ui, {path, depth, t}, q) do
    id = path_str(path)
    errors = Types.errors(m, path)
    editing = ui.edit && elem(ui.edit, 0) == id && elem(ui.edit, 1)
    open? = open?(t, path, ui, q)

    chev =
      cond do
        t.components == [] ->
          ~s|<span class="tchev"></span>|

        true ->
          ~s|<span class="tchev" data-click="ttoggle:#{id}" aria-hidden="true"><svg viewBox="0 0 12 12"><path d="#{if open?, do: "M2.5 4.5 6 8l3.5-3.5", else: "M4.5 2.5 8 6l-3.5 3.5"}"/></svg></span>|
      end

    name =
      if editing == :name,
        do:
          ~s|<input class="tedit" data-tedit data-op="tname" data-path="#{id}" value="#{Fmt.esc(t.name)}" spellcheck="false" aria-label="Name"/>|,
        else:
          ~s|<span class="tname#{if t.ref == nil, do: " struct"}" data-tname="#{id}" title="Double click to rename">#{mark(t.name, q)}</span>|

    type =
      if editing == :type,
        do:
          ~s|<select class="tedit" data-tedit data-op="tref" data-path="#{id}" aria-label="Type">#{type_options(m, t, depth)}</select>|,
        else:
          ~s|<span class="ttype#{if custom_ref?(m, t), do: " custom"}" data-click="ttype:#{id}" title="Click to change the type">#{type_label(t)}</span>|

    add =
      if t.ref == nil,
        do: ~s|<button data-click="tadd-child:#{id}" title="Add a field" aria-label="Add a field">＋</button>|,
        else: ""

    IO.iodata_to_binary([
      ~s|<div class="trow#{if ui.sel == id, do: " sel"}#{if errors != [], do: " err"}" id="trow-#{id}" role="treeitem" aria-level="#{depth + 1}" aria-selected="#{ui.sel == id}" data-click="tsel:#{id}" style="--d:#{depth}">|,
      ~s|<span class="tcell-name">#{chev}<span class="ticon #{icon_class(m, t)}" aria-hidden="true">#{icon(m, t)}</span>#{name}|,
      if(errors != [], do: ~s|<span class="terr" title="#{Fmt.esc(Enum.join(errors, "; "))}">!</span>|, else: ""),
      ~s|</span>#{type}<span class="tcons" title="#{Fmt.esc(summary_title(t))}">#{summary(t)}</span>|,
      ~s|<span class="tact">#{add}<button data-click="tdel:#{id}" title="Delete" aria-label="Delete">✕</button></span></div>|
    ])
  end

  defp mark(name, ""), do: Fmt.esc(name)

  defp mark(name, q) do
    lower = String.downcase(name)

    # byte offsets of the match are only valid in `name` when lowercasing did not change its length
    with true <- byte_size(lower) == byte_size(name), {at, len} <- :binary.match(lower, q) do
      Fmt.esc(binary_part(name, 0, at)) <>
        "<mark>" <>
        Fmt.esc(binary_part(name, at, len)) <>
        "</mark>" <> Fmt.esc(binary_part(name, at + len, byte_size(name) - at - len))
    else
      _ -> Fmt.esc(name)
    end
  end

  defp type_label(t), do: Fmt.esc(t.ref || "Structure") <> if(t.collection, do: ~s|<b class="coll">[]</b>|, else: "")

  defp custom_ref?(m, t), do: t.ref not in [nil, ""] and t.ref not in Types.builtins() and Types.find(m, t.ref) != nil

  @doc false
  def summary(%{constraint: nil}), do: ~s|<span class="none">—</span>|
  def summary(%{constraint: %{text: ""}}), do: ~s|<span class="none">—</span>|
  def summary(%{constraint: %{text: text}}), do: Fmt.esc(text)
  defp summary_title(%{constraint: %{kind: kind, text: text}}) when text != "", do: "#{kind}: #{text}"
  defp summary_title(_), do: "No constraint"

  defp icon(m, t) do
    case Types.base(m, t) do
      nil -> "{ }"
      "number" -> "#"
      "string" -> "Aa"
      "boolean" -> "✓"
      b when b in ["date", "time", "date and time", "days and time duration", "years and months duration"] -> "◷"
      "context" -> "{ }"
      _ -> "∗"
    end
  end

  defp icon_class(m, t), do: if(Types.base(m, t) == nil and t.ref in [nil, ""], do: "k-struct", else: "k-prim")

  # --- inspector -------------------------------------------------------------------------

  def inspector(%Model{} = m, ui) do
    case sel_path(m, ui) do
      nil -> ~s|<p class="hint">Select a data type or a field to edit its properties.</p>|
      path -> inspector(m, ui, path, Types.fetch(m.types, path))
    end
  end

  defp inspector(m, ui, path, t) do
    id = path_str(path)
    depth = length(path) - 1
    name_err = Types.name_error(m.types, path)

    IO.iodata_to_binary([
      ~s|<header class="ihead"><span class="ticon #{icon_class(m, t)}" aria-hidden="true">#{icon(m, t)}</span>|,
      ~s|<div><b id="ititle-#{id}">#{Fmt.esc(t.name)}</b><small>#{if depth == 0, do: "Data type", else: "Field"}#{if t.ref == nil, do: " · structure"}</small></div>|,
      ~s|<button class="close" data-click="tinsp-toggle" title="Close properties" aria-label="Close properties">✕</button></header>|,
      ~s|<div class="ibody">|,
      field(
        "Name",
        ~s|<input data-op="tname" data-path="#{id}" value="#{Fmt.esc(t.name)}" spellcheck="false" id="iname"/><small class="bad" id="tmsg-#{id}">#{Fmt.esc(name_err || "")}</small>|,
        "iname"
      ),
      field(
        "Type",
        ~s|<select data-op="tref" data-path="#{id}" id="itype">#{type_options(m, t, depth)}</select>#{ref_note(m, t)}|,
        "itype"
      ),
      ~s|<label class="switch"><input type="checkbox" data-op="tcoll" data-path="#{id}"#{if t.collection, do: " checked"}/><span>List <small>(a collection of this type)</small></span></label>|,
      ~s|<section class="isec"><h4>Allowed values</h4>#{constraint(m, ui, id, t)}</section>|,
      if(depth == 0, do: used_by(m, t), else: ""),
      ~s|</div><footer class="ifoot">|,
      if(t.ref == nil, do: ~s|<button data-click="tadd-child:#{id}">＋ Add field</button>|, else: ""),
      ~s|<button class="danger" data-click="tdel:#{id}">Delete</button></footer>|
    ])
  end

  defp field(label, control, for_id),
    do: ~s|<div class="ifield"><label for="#{for_id}">#{label}</label>#{control}</div>|

  defp ref_note(m, t) do
    case Types.ref_error(m, t) do
      nil -> ""
      msg -> ~s|<small class="bad">#{Fmt.esc(msg)}</small>|
    end
  end

  @doc "Grouped options for a type reference: structure, built-in and the custom types (a top-level type cannot be its own base)."
  def type_options(%Model{} = m, t, depth) do
    cur = t.ref || ""
    opt = fn v, label -> ~s|<option value="#{Fmt.esc(v)}"#{if v == cur, do: " selected"}>#{Fmt.esc(label)}</option>| end
    custom = for x <- m.types, x.name != t.name or depth > 0, do: x.name

    IO.iodata_to_binary([
      opt.("", "Structure"),
      ~s|<optgroup label="Built-in">#{Enum.map(Types.builtins(), &opt.(&1, &1))}</optgroup>|,
      if(custom == [], do: "", else: ~s|<optgroup label="Custom">#{Enum.map(custom, &opt.(&1, &1))}</optgroup>|)
    ])
  end

  defp used_by(m, t) do
    u = Types.usages(m, t.name)

    items =
      Enum.map(u.nodes, &"<li>#{Fmt.esc(&1)} <small>node</small></li>") ++
        Enum.map(u.types, &"<li>#{Fmt.esc(&1)} <small>type</small></li>")

    ~s|<section class="isec"><h4>Used by</h4>#{if items == [], do: ~s|<p class="muted">Not used yet.</p>|, else: "<ul class=\"usedby\">#{items}</ul>"}</section>|
  end

  # --- constraint editor -------------------------------------------------------------------

  @doc "How the constraint is shown: `:none`, `:feel` (raw text) or the visual form `{:cmp, ..} | {:interval, ..} | {:list, ..}`."
  def mode(nil, _adv?), do: :none

  def mode(%{kind: kind, text: text}, adv?) do
    form = Constraint.parse(text, kind)

    cond do
      adv? or form == :advanced -> :feel
      true -> form
    end
  end

  defp mode_key(:none), do: :none
  defp mode_key(:feel), do: :feel
  defp mode_key(form), do: elem(form, 0)

  def constraint(m, ui, id, t) do
    adv? = MapSet.member?(ui.adv, id)
    form = mode(t.constraint, adv?)
    key = mode_key(form)
    # a text the visual editors cannot reproduce stays as FEEL; the visual modes would overwrite it
    locked? = t.constraint != nil and Constraint.parse(t.constraint.text, t.constraint.kind) == :advanced

    buttons =
      for {mode, label} <- @modes do
        disabled =
          if locked? and mode not in [:none, :feel],
            do: " disabled title=\"This expression cannot be shown visually; clear it first\"",
            else: ""

        ~s|<button data-click="cmode:#{id}:#{mode}" aria-pressed="#{key == mode}"#{disabled}>#{label}</button>|
      end

    IO.iodata_to_binary([
      ~s|<div class="seg" role="group" aria-label="Constraint kind">#{buttons}</div>|,
      editor(m, id, t, form),
      ~s|<small class="bad" id="cmsg-#{id}">#{message(t.constraint && Types.constraint_error(t.constraint))}</small>|
    ])
  end

  defp editor(_m, _id, _t, :none), do: ~s|<p class="muted">Any value of the type is allowed.</p>|

  defp editor(_m, id, _t, {:cmp, op, lit}) do
    opts = for {v, label} <- @ops, do: ~s|<option value="#{Fmt.esc(v)}"#{if v == op, do: " selected"}>#{label}</option>|

    ~s|<div class="crow"><select data-op="cop" data-path="#{id}" aria-label="Operator">#{opts}</select><input data-op="cval" data-path="#{id}" value="#{Fmt.esc(lit)}" inputmode="decimal" spellcheck="false" aria-label="Value"/></div>|
  end

  defp editor(_m, id, _t, {:interval, lo, a, b, hi}) do
    sel = fn op, cur, choices ->
      ~s|<select data-op="#{op}" data-path="#{id}" aria-label="#{op}">#{for c <- choices, do: ~s|<option#{if c == cur, do: " selected"}>#{c}</option>|}</select>|
    end

    ~s|<div class="crow">#{sel.("clo", lo, ["[", "("])}<input data-op="ca" data-path="#{id}" value="#{Fmt.esc(a)}" inputmode="decimal" spellcheck="false" aria-label="From"/><span>…</span><input data-op="cb" data-path="#{id}" value="#{Fmt.esc(b)}" inputmode="decimal" spellcheck="false" aria-label="To"/>#{sel.("chi", hi, ["]", ")"])}</div>|
  end

  defp editor(_m, id, _t, {:list, items}) do
    chips =
      for {item, i} <- Enum.with_index(items),
          do:
            ~s|<span class="chip">#{Fmt.esc(item)}<button data-click="cdel:#{id}:#{i}" aria-label="Remove #{Fmt.esc(item)}">✕</button></span>|

    ~s|<div class="chips">#{chips}</div><input data-op="citem" data-path="#{id}" placeholder="Add a value and press Enter" spellcheck="false" aria-label="New value"/>|
  end

  defp editor(_m, id, t, :feel) do
    c = t.constraint
    err = Types.constraint_error(c)
    kinds = for k <- Types.kinds(), do: ~s|<option value="#{k}"#{if k == c.kind, do: " selected"}>#{k}</option>|

    IO.iodata_to_binary([
      ~s|<div class="ed"><pre class="hl" id="chl-#{id}">#{Highlight.html(c.text, err && err.span)}</pre>|,
      ~s|<textarea data-op="ctext" data-path="#{id}" rows="2" spellcheck="false" autocomplete="off" aria-label="FEEL expression">#{Fmt.esc(c.text)}</textarea></div>|,
      ~s|<label class="kindsel">stored as <select data-op="ckind" data-path="#{id}">#{kinds}</select></label>|
    ])
  end

  def message(nil), do: ""
  def message(err), do: Fmt.esc(err.message)
end
