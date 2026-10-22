defmodule DmnSpike.TypesPanel do
  @moduledoc "The Data types tab: an editable tree of item definitions."

  alias DmnSpike.{Fmt, Highlight, Model, Types}

  def render(%Model{types: []}, _sel),
    do: ~s|<p class="hint">No data types yet.</p><button data-click="add-type">+ Add data type</button>|

  def render(%Model{} = m, sel) do
    sel = sel |> max(0) |> min(length(m.types) - 1)
    t = Enum.at(m.types, sel)

    IO.iodata_to_binary([
      ~s|<div class="tsplit"><nav class="tlist" aria-label="Data types">|,
      for({x, i} <- Enum.with_index(m.types), do: item(x, i, i == sel)),
      ~s|<button class="tadd" data-click="add-type">+ Data type</button></nav><section class="tdetail">|,
      ~s|<table class="types"><thead><tr><th>Name</th><th>Type</th><th>List</th><th>Constraint</th><th></th></tr></thead><tbody>|,
      rows(m, t, [sel], 0),
      ~s|</tbody></table></section></div>|
    ])
  end

  defp item(t, i, on?) do
    ~s|<button class="titem#{if on?, do: " on"}" data-click="pick-type:#{i}"><b id="tn-#{i}">#{Fmt.esc(t.name)}</b><small>#{summary(t)}</small></button>|
  end

  defp summary(%{components: [_ | _] = cs} = t),
    do: "#{if t.collection, do: "list of "}structure · #{length(cs)} field#{if length(cs) != 1, do: "s"}"

  defp summary(t), do: "#{if t.collection, do: "list of "}#{Fmt.esc(t.ref || "structure")}"

  def path_id(path), do: Enum.join(path, "-")

  def constraint_html(t, path) do
    id = path_id(path)
    c = t.constraint

    kinds =
      for k <- [nil | Types.kinds()] do
        sel = if (c && c.kind) == k, do: " selected", else: ""
        ~s|<option value="#{k}"#{sel}>#{if k, do: k, else: "none"}</option>|
      end

    editor =
      if c do
        err = Types.constraint_error(c)

        [
          ~s|<div class="ed"><pre class="hl" id="chl-#{id}">#{Highlight.html(c.text, err && err.span)}</pre>|,
          ~s|<textarea data-op="ctext" data-path="#{id}" rows="1" spellcheck="false" autocomplete="off">#{Fmt.esc(c.text)}</textarea></div>|,
          ~s|<small class="bad" id="cmsg-#{id}">#{message(err)}</small>|
        ]
      else
        []
      end

    IO.iodata_to_binary([~s|<select data-op="ckind" data-path="#{id}">#{kinds}</select>|, editor])
  end

  def message(nil), do: ""
  def message(err), do: Fmt.esc(err.message)

  defp rows(m, t, path, depth) do
    id = path_id(path)
    custom = for x <- m.types, x.name != t.name or depth > 0, do: x.name

    opts =
      for ref <- [""] ++ Types.builtins() ++ custom do
        sel = if ref == (t.ref || ""), do: " selected", else: ""
        ~s|<option value="#{Fmt.esc(ref)}"#{sel}>#{if ref == "", do: "Structure", else: Fmt.esc(ref)}</option>|
      end

    row = [
      ~s|<tr><td style="padding-left:#{0.5 + depth * 1.4}rem"><input data-op="tname" data-path="#{id}" value="#{Fmt.esc(t.name)}" spellcheck="false"/></td>|,
      ~s|<td><select data-op="tref" data-path="#{id}">#{opts}</select></td>|,
      ~s|<td><input type="checkbox" data-op="tcoll" data-path="#{id}"#{if t.collection, do: " checked"}/></td>|,
      ~s|<td class="cons">#{constraint_html(t, path)}</td>|,
      ~s|<td class="acts">#{if t.ref == nil, do: ~s|<button data-click="add-child:#{id}" title="Add field">+ field</button>|}<button data-click="del-type:#{id}" title="Delete">✕</button></td></tr>|
    ]

    kids = t.components |> Enum.with_index() |> Enum.flat_map(fn {c, i} -> rows(m, c, path ++ [i], depth + 1) end)
    [IO.iodata_to_binary(row) | kids]
  end
end
