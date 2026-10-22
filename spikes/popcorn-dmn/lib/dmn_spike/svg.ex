defmodule DmnSpike.Svg do
  @moduledoc "Renders nodes and edges as SVG markup."

  alias DmnSpike.{Fmt, Model}

  def scene(%Model{} = m, values, selected) do
    edges = m.edges |> Enum.with_index() |> Enum.map(fn {e, i} -> [~s|<g id="edge-#{i}">|, edge(m, e), "</g>"] end)
    nodes = m.nodes |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&node(&1, values[&1.id], selected))
    IO.iodata_to_binary([edges, nodes])
  end

  def edge(%Model{nodes: nodes}, {from, to, kind}) do
    a = nodes[from]
    b = nodes[to]
    {x1, y1} = border(a, center(b))
    {x2, y2} = border(b, center(a))
    dash = if kind == :knowledge, do: ~s| stroke-dasharray="6 4"|, else: ""
    marker = if kind == :knowledge, do: "arrow-open", else: "arrow-fill"

    ~s|<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" stroke="currentColor"#{dash} marker-end="url(##{marker})"/>|
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

  def transform(n), do: "translate(#{n.x} #{n.y})"

  def node_value_text(nil), do: ""
  def node_value_text(%{value: v}), do: Fmt.short(v)

  defp node(n, result, selected) do
    [
      ~s|<g class="node#{if n.id == selected, do: " sel"}" data-id="#{n.id}" transform="#{transform(n)}">|,
      shape(n),
      ~s|<text x="#{div(n.w, 2)}" y="26" text-anchor="middle" font-size="13" fill="currentColor">#{Fmt.esc(n.name)}</text>|,
      ~s|<text id="nv-#{n.id}" class="nv" x="#{div(n.w, 2)}" y="45" text-anchor="middle" font-size="12">#{Fmt.esc(node_value_text(result))}</text>|,
      "</g>"
    ]
  end

  defp shape(%{type: :decision} = n), do: ~s|<rect class="shape" width="#{n.w}" height="#{n.h}"/>|
  defp shape(%{type: :input} = n), do: ~s|<rect class="shape" width="#{n.w}" height="#{n.h}" rx="#{div(n.h, 2)}"/>|

  defp shape(%{type: :bkm} = n) do
    c = 14
    pts = [{c, 0}, {n.w, 0}, {n.w, n.h}, {0, n.h}, {0, c}]
    ~s|<polygon class="shape" points="#{Enum.map_join(pts, " ", fn {x, y} -> "#{x},#{y}" end)}"/>|
  end
end
