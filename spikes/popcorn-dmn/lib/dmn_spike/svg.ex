defmodule DmnSpike.Svg do
  @moduledoc "Renders nodes and edges as SVG markup."

  alias DmnSpike.{Fmt, Model}

  def scene(%Model{} = m, results, selected, sel_edge \\ nil) do
    edges =
      m.edges
      |> Enum.with_index()
      |> Enum.map(fn {e, i} ->
        [~s|<g id="edge-#{i}" class="#{edge_class(i == sel_edge)}" data-edge="#{i}">|, edge(m, e, i), "</g>"]
      end)

    nodes =
      m.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&node(&1, results[&1.id], selected))

    IO.iodata_to_binary([edges, nodes])
  end

  def edge_class(selected?), do: if(selected?, do: "edge sel", else: "edge")

  def edge(%Model{nodes: nodes}, {from, to, kind}, _i) do
    {x1, y1, x2, y2} = endpoints(nodes[from], nodes[to])
    dash = if kind == :knowledge, do: ~s| stroke-dasharray="6 4"|, else: ""
    marker = if kind == :knowledge, do: "arrow-open", else: "arrow-fill"

    [
      ~s|<line class="hit" x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}"/>|,
      ~s|<line class="vis" x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" stroke="currentColor"#{dash} marker-end="url(##{marker})"/>|
    ]
    |> IO.iodata_to_binary()
  end

  def endpoints(a, b) do
    {x1, y1} = border(a, center(b))
    {x2, y2} = border(b, center(a))
    {x1, y1, x2, y2}
  end

  def preview(%Model{nodes: nodes}, from, {px, py}) do
    {x1, y1} = border(nodes[from], {px, py})

    ~s|<line x1="#{x1}" y1="#{y1}" x2="#{Float.round(px * 1.0, 1)}" y2="#{Float.round(py * 1.0, 1)}" stroke="currentColor" stroke-dasharray="3 3" marker-end="url(#arrow-fill)"/>|
  end

  def center(n), do: {n.x + n.w / 2, n.y + n.h / 2}

  @doc "Point where the ray from the centre of `n` towards `{tx, ty}` leaves its rectangle."
  def border(n, {tx, ty}) do
    {cx, cy} = center(n)
    {dx, dy} = {tx - cx, ty - cy}
    sx = if dx == 0, do: :infinity, else: n.w / 2 / abs(dx)
    sy = if dy == 0, do: :infinity, else: n.h / 2 / abs(dy)
    t = min_num(sx, sy)
    t = if t == :infinity, do: 0, else: t
    {Float.round(cx + dx * t, 1), Float.round(cy + dy * t, 1)}
  end

  defp min_num(:infinity, b), do: b
  defp min_num(a, :infinity), do: a
  defp min_num(a, b), do: min(a, b)

  @doc "viewBox that fits every node with a margin, never smaller than the default canvas."
  def viewbox(%Model{nodes: nodes}) when map_size(nodes) == 0, do: "0 0 820 370"

  def viewbox(%Model{nodes: nodes}) do
    ns = Map.values(nodes)
    minx = min(0, Enum.min(Enum.map(ns, & &1.x)) - 30)
    miny = min(0, Enum.min(Enum.map(ns, & &1.y)) - 30)
    maxx = Enum.max(Enum.map(ns, &(&1.x + &1.w))) + 30
    maxy = Enum.max(Enum.map(ns, &(&1.y + &1.h))) + 30
    "#{minx} #{miny} #{max(maxx - minx, 820)} #{max(maxy - miny, 370)}"
  end

  def transform(n), do: "translate(#{n.x} #{n.y})"

  def node_class(selected?, invalid?),
    do: "node" <> if(selected?, do: " sel", else: "") <> if(invalid?, do: " invalid", else: "")

  def node_value_text(nil), do: ""
  def node_value_text(%{value: nil}), do: "—"
  def node_value_text(%{value: v}), do: Fmt.short(v)

  def node_title(nil), do: ""
  def node_title(%{value: v, errors: errors}), do: Fmt.esc(Enum.join(["value: " <> Fmt.value(v) | errors], "\n"))

  defp node(n, result, selected) do
    invalid? = result != nil and result.errors != []

    [
      ~s|<g class="#{node_class(n.id == selected, invalid?)}" data-id="#{n.id}" transform="#{transform(n)}">|,
      ~s|<title id="tt-#{n.id}">#{node_title(result)}</title>|,
      shape(n),
      ~s|<text id="nm-#{n.id}" x="#{div(n.w, 2)}" y="26" text-anchor="middle" font-size="13" fill="currentColor">#{Fmt.esc(n.name)}</text>|,
      ~s|<text id="nv-#{n.id}" class="nv" x="#{div(n.w, 2)}" y="45" text-anchor="middle" font-size="12">#{Fmt.esc(node_value_text(result))}</text>|,
      ~s|<g class="handle" data-handle="#{n.id}" transform="translate(#{div(n.w, 2)} 0)"><title>Drag onto a node that needs this one</title><circle r="10"/><path d="M0 4V-4M-3.5 -1L0 -4.5L3.5 -1"/></g>|,
      ~s|<g class="del" data-del="#{n.id}" transform="translate(#{n.w} 0)"><title>Delete (Del)</title><circle r="9"/><path d="M-3 -3L3 3M3 -3L-3 3"/></g>|,
      ~s|<g id="pad-#{n.id}">#{if n.id == selected, do: pad(n)}</g>|,
      "</g>"
    ]
  end

  @icons %{
    "decision" => ~s|<rect x="-8" y="-6" width="16" height="12" rx="2"/>|,
    "input" => ~s|<rect x="-9" y="-6" width="18" height="12" rx="6"/>|,
    "bkm" => ~s|<path d="M-9 -2L-5 -6H9V6H-9Z" stroke-linejoin="round"/>|
  }
  @labels %{"decision" => "decision", "input" => "input data", "bkm" => "business knowledge"}

  @doc "Everything that floats around a selected node: its data type and create-and-connect buttons."
  def pad(n), do: [type_pill(n), create_buttons(n)] |> IO.iodata_to_binary()

  defp type_pill(n) do
    label = n.type_ref || "no type"
    w = 36 + round(String.length(label) * 7.2)

    ~s|<g class="tpill#{if n.type_ref == nil, do: " none"}" data-typepill="#{n.id}" transform="translate(0 -40)"><title>Data type: click to change</title><rect width="#{w}" height="24" rx="12"/><text x="12" y="16" font-size="11.5">#{Fmt.esc(label)}</text><path d="M#{w - 18} 10l4 4l4 -4" /></g>|
  end

  defp create_buttons(n) do
    case Model.required_kinds(n.type) do
      [] ->
        ""

      kinds ->
        w = 8 + 30 * length(kinds)

        buttons =
          for {k, i} <- Enum.with_index(kinds) do
            ~s|<g class="mk" data-create="#{k}" transform="translate(#{19 + 30 * i} 16)"><title>Add #{@labels[k]} this requires</title><rect class="hit" x="-15" y="-15" width="30" height="30" rx="8"/>#{@icons[k]}</g>|
          end

        ~s|<g class="pad" transform="translate(#{n.w + 16} #{div(n.h - 32, 2)})"><rect class="bg" width="#{w}" height="32" rx="16"/>#{buttons}</g>|
    end
  end

  defp shape(%{type: :decision} = n), do: ~s|<rect class="shape decision" width="#{n.w}" height="#{n.h}" rx="5"/>|

  defp shape(%{type: :input} = n),
    do: ~s|<rect class="shape input" width="#{n.w}" height="#{n.h}" rx="#{div(n.h, 2)}"/>|

  # business knowledge: a rectangle with both top corners cut
  defp shape(%{type: :bkm} = n) do
    c = 14
    pts = [{c, 0}, {n.w - c, 0}, {n.w, c}, {n.w, n.h}, {0, n.h}, {0, c}]

    ~s|<polygon class="shape bkm" points="#{Enum.map_join(pts, " ", fn {x, y} -> "#{x},#{y}" end)}" stroke-linejoin="round"/>|
  end
end
