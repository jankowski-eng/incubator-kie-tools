defmodule DmnSpike.Svg do
  @moduledoc "Renders nodes and edges as SVG markup."

  alias DmnSpike.{Fmt, Model}

  def scene(%Model{} = m, results, selected, sel_edge \\ nil) do
    edges =
      m
      |> Model.edges_all()
      |> Enum.with_index()
      |> Enum.map(fn {e, i} ->
        [~s|<g id="edge-#{i}" class="#{edge_class(i == sel_edge)}" data-edge="#{i}">|, edge(m, e, i), "</g>"]
      end)

    nodes =
      m.nodes
      |> Map.values()
      |> Enum.sort_by(&{&1.type != :group, &1.id})
      |> Enum.map(&node(&1, results[&1.id], selected))

    IO.iodata_to_binary([edges, nodes])
  end

  def edge_class(selected?), do: if(selected?, do: "edge sel", else: "edge")

  def edge(%Model{} = m, {from, to, kind}, _i) do
    {x1, y1, x2, y2} = endpoints(m, from, to)

    {dash, marker} =
      case kind do
        :knowledge -> {~s| stroke-dasharray="6 4"|, ~s| marker-end="url(#arrow-open)"|}
        :authority -> {~s| stroke-dasharray="6 4"|, ~s| marker-end="url(#dot)"|}
        :association -> {~s| stroke-dasharray="2 4"|, ""}
        _ -> {"", ~s| marker-end="url(#arrow-fill)"|}
      end

    [
      ~s|<line class="hit" x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}"/>|,
      ~s|<line class="vis" x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" stroke="currentColor"#{dash}#{marker}/>|
    ]
    |> IO.iodata_to_binary()
  end

  @doc "Ends of the edge from `from` to `to`: at the chosen side of `to`, or where the line between the centres leaves each node."
  def endpoints(%Model{nodes: nodes, anchors: anchors}, from, to) do
    {a, b} = {nodes[from], nodes[to]}

    {x2, y2} =
      case anchors[{from, to}] do
        nil -> border(b, center(a))
        side -> anchor_point(b, side)
      end

    {x1, y1} = border(a, if(anchors[{from, to}], do: {x2, y2}, else: center(b)))
    {x1, y1, x2, y2}
  end

  def anchor_point(n, :top), do: {n.x + n.w / 2, n.y * 1.0}
  def anchor_point(n, :bottom), do: {n.x + n.w / 2, n.y + n.h * 1.0}
  def anchor_point(n, :left), do: {n.x * 1.0, n.y + n.h / 2}
  def anchor_point(n, :right), do: {n.x + n.w * 1.0, n.y + n.h / 2}

  @doc "The side of `n` whose anchor is closest to `{x, y}`."
  def nearest_side(n, {x, y}),
    do:
      Enum.min_by([:top, :right, :bottom, :left], fn side ->
        {ax, ay} = anchor_point(n, side)
        (ax - x) * (ax - x) + (ay - y) * (ay - y)
      end)

  @doc "The dashed line while connecting: it ends at the pointer, or snaps to the anchor of the node `over` it that is nearest to the pointer."
  def preview(%Model{nodes: nodes}, from, over, {px, py}) do
    {x2, y2} = if over, do: anchor_point(over, nearest_side(over, {px, py})), else: {px, py}
    {x1, y1} = border(nodes[from], {x2, y2})

    ~s|<line x1="#{x1}" y1="#{y1}" x2="#{Float.round(x2 * 1.0, 1)}" y2="#{Float.round(y2 * 1.0, 1)}" stroke="currentColor" stroke-dasharray="3 3" marker-end="url(#arrow-fill)"/>|
  end

  def center(n), do: {n.x + n.w / 2, n.y + n.h / 2}

  @bkm_cut 14

  @doc """
  Point where the ray from the centre of `n` towards `{tx, ty}` leaves the outline of `n`: the capsule of an
  input, the cut-cornered polygon of a business knowledge model, the rectangle of everything else.
  """
  def border(n, {tx, ty}) do
    {cx, cy} = center(n)
    {dx, dy} = {tx - cx, ty - cy}

    t =
      cond do
        dx == 0 and dy == 0 -> 0
        n.type == :input -> capsule_t(n, dx, dy)
        n.type == :bkm -> polygon_t(n, bkm_points(n), dx, dy)
        true -> rect_t(n, dx, dy)
      end

    {Float.round(cx + dx * t, 1), Float.round(cy + dy * t, 1)}
  end

  defp rect_t(n, dx, dy) do
    sx = if dx == 0, do: :infinity, else: n.w / 2 / abs(dx)
    sy = if dy == 0, do: :infinity, else: n.h / 2 / abs(dy)
    min_num(sx, sy)
  end

  # a rectangle whose short sides are half circles: leave through the flat top or bottom, else the round end
  defp capsule_t(n, dx, dy) do
    r = n.h / 2
    a = max(n.w / 2 - r, 0.0)
    k = dx * dx + dy * dy

    cond do
      dy == 0 -> n.w / 2 / abs(dx)
      r / abs(dy) * abs(dx) <= a -> r / abs(dy)
      true -> (a * abs(dx) + :math.sqrt(max(r * r * k - a * a * dy * dy, 0.0))) / k
    end
  end

  # the corners the shape cuts: top left and bottom right (DMN's business knowledge model)
  defp bkm_points(n) do
    c = min(@bkm_cut, min(n.w, n.h) / 2)

    [{c, 0}, {n.w, 0}, {n.w, n.h - c}, {n.w - c, n.h}, {0, n.h}, {0, c}]
    |> Enum.map(fn {x, y} -> {n.x + x, n.y + y} end)
  end

  # the first edge of the polygon the ray from the centre hits
  defp polygon_t(n, pts, dx, dy) do
    {cx, cy} = center(n)

    pts
    |> Enum.zip(tl(pts) ++ [hd(pts)])
    |> Enum.flat_map(fn {{x1, y1}, {x2, y2}} ->
      {ex, ey} = {x2 - x1, y2 - y1}
      denom = dx * ey - dy * ex
      {px, py} = {x1 - cx, y1 - cy}

      if denom == 0 do
        []
      else
        t = (px * ey - py * ex) / denom
        s = (px * dy - py * dx) / denom
        if t > 0 and s >= -1.0e-9 and s <= 1 + 1.0e-9, do: [t], else: []
      end
    end)
    |> Enum.min(fn -> rect_t(n, dx, dy) end)
  end

  defp min_num(:infinity, b), do: b
  defp min_num(a, :infinity), do: a
  defp min_num(a, b), do: min(a, b)

  @doc "viewBox that fits every node with a margin, never smaller than the default canvas."
  def viewbox(%Model{nodes: nodes}) when map_size(nodes) == 0, do: "0 0 820 370"

  def viewbox(%Model{nodes: nodes}) do
    ns = Map.values(nodes)
    # 60 more on the left keeps the floating palette off the diagram
    minx = min(0, Enum.min(Enum.map(ns, & &1.x)) - 30) - 60
    miny = min(0, Enum.min(Enum.map(ns, & &1.y)) - 30)
    maxx = Enum.max(Enum.map(ns, &(&1.x + &1.w))) + 30
    maxy = Enum.max(Enum.map(ns, &(&1.y + &1.h))) + 30
    "#{minx} #{miny} #{max(maxx - minx, 820)} #{max(maxy - miny, 370)}"
  end

  def transform(n), do: "translate(#{n.x} #{n.y})"

  # artifacts keep their type as a class so that selecting them does not lose their styling
  def node_class(selected?, invalid?, type \\ nil),
    do:
      "node" <>
        if(selected?, do: " sel", else: "") <>
        if(invalid?, do: " invalid", else: "") <> if(Model.artifact?(%{type: type}), do: " #{type}", else: "")

  def node_value_text(nil), do: ""
  def node_value_text(%{value: nil}), do: "—"
  def node_value_text(%{value: v}), do: Fmt.short(v)

  @doc "The badge text as HTML: values come from FEEL strings, so they must be escaped wherever they are inserted."
  def node_value_html(result), do: Fmt.esc(node_value_text(result))

  def node_title(nil), do: ""
  def node_title(%{value: v, errors: errors}), do: Fmt.esc(Enum.join(["value: " <> Fmt.value(v) | errors], "\n"))

  def node_html(n, result, selected), do: n |> node(result, selected) |> IO.iodata_to_binary()

  defp node(%{type: :group} = n, _result, selected) do
    [
      ~s|<g class="#{node_class(n.id == selected, false, n.type)}" data-id="#{n.id}" transform="#{transform(n)}">|,
      shape(n),
      ~s|<text id="nm-#{n.id}" class="gname" x="12" y="19" font-size="12.5">#{Fmt.esc(n.name)}</text>|,
      resize_handle(n),
      del(n),
      ~s|<g id="info-#{n.id}"></g>|,
      ~s|<g id="pad-#{n.id}"></g>|,
      "</g>"
    ]
  end

  defp node(%{type: :annotation} = n, _result, selected) do
    [
      ~s|<g class="#{node_class(n.id == selected, false, n.type)}" data-id="#{n.id}" transform="#{transform(n)}">|,
      shape(n),
      ~s|<foreignObject x="10" y="4" width="#{max(n.w - 14, 10)}" height="#{max(n.h - 8, 10)}"><div class="atext" id="nm-#{n.id}">#{Fmt.esc(n.name)}</div></foreignObject>|,
      handle(n),
      resize_handle(n),
      del(n),
      ~s|<g id="info-#{n.id}"></g>|,
      ~s|<g id="pad-#{n.id}">#{if n.id == selected, do: pad(n)}</g>|,
      "</g>"
    ]
  end

  defp node(n, result, selected) do
    invalid? = result != nil and result.errors != []

    [
      ~s|<g class="#{node_class(n.id == selected, invalid?)}" data-id="#{n.id}" transform="#{transform(n)}">|,
      ~s|<title id="tt-#{n.id}">#{if Model.artifact?(n), do: "", else: node_title(result)}</title>|,
      shape(n),
      ~s|<text id="nm-#{n.id}" x="#{div(n.w, 2)}" y="#{if Model.artifact?(n), do: div(n.h, 2) - 4, else: 26}" text-anchor="middle" font-size="13" fill="currentColor">#{Fmt.esc(n.name)}</text>|,
      ~s|<text id="nv-#{n.id}" class="nv" x="#{div(n.w, 2)}" y="45" text-anchor="middle" font-size="12">#{if(Model.artifact?(n), do: "", else: node_value_html(result))}</text>|,
      handle(n),
      del(n),
      ~s|<g id="info-#{n.id}">#{info(n)}</g>|,
      ~s|<g id="pad-#{n.id}">#{if n.id == selected, do: pad(n)}</g>|,
      "</g>"
    ]
  end

  # The connect handle sits just outside the right edge and shows on hover; the hover pad keeps the node hovered on the
  # way to it. While a connection is dragged, a valid target shows four anchors in a cross (see `anchors/1`).
  defp handle(n) do
    [
      ~s|<rect class="hoverpad" x="#{n.w}" y="0" width="24" height="#{n.h}"/>|,
      ~s|<g class="handle" data-handle="#{n.id}" transform="translate(#{n.w + 12} #{div(n.h, 2)})"><title>Click or drag to connect to a node that requires this one</title><circle r="7"/><path d="M-3 0H3M0.5-2.5 3 0 0.5 2.5"/></g>|,
      anchors(n)
    ]
  end

  defp anchors(n) do
    for {side, x, y} <- [
          {:top, div(n.w, 2), 0},
          {:right, n.w, div(n.h, 2)},
          {:bottom, div(n.w, 2), n.h},
          {:left, 0, div(n.h, 2)}
        ] do
      ~s|<circle class="anchor" data-side="#{side}" cx="#{x}" cy="#{y}" r="6"/>|
    end
  end

  defp resize_handle(n),
    do:
      ~s|<g class="resize" data-resize="#{n.id}" transform="translate(#{n.w} #{n.h})"><title>Resize</title><rect x="-14" y="-14" width="14" height="14"/><path d="M-10 -2L-2 -10M-6 -2L-2 -6"/></g>|

  defp del(n),
    do:
      ~s|<g class="del" data-del="#{n.id}" transform="translate(#{n.w} 0)"><title>Delete (Del)</title><circle r="9"/><path d="M-3 -3L3 3M3 -3L-3 3"/></g>|

  @icons %{
    "source" => ~s|<path d="M-8 -6H8V3C4 0 4 6 0 3S-4 0 -8 3Z" stroke-linejoin="round"/>|,
    "annotation" => ~s|<path d="M-2 -6H-8V6H-2M1 -2H8M1 2H6"/>|,
    "decision" => ~s|<rect x="-8" y="-6" width="16" height="12" rx="2"/>|,
    "input" => ~s|<rect x="-9" y="-6" width="18" height="12" rx="6"/>|,
    "bkm" => ~s|<path d="M-5 -6H9V2L5 6H-9V-2Z" stroke-linejoin="round"/>|
  }
  @labels %{
    "decision" => "decision this requires",
    "input" => "input data this requires",
    "bkm" => "business knowledge this requires",
    "annotation" => "text annotation",
    "source" => "knowledge source"
  }

  @doc "The small ⓘ on a node that has a description; its tooltip is the description."
  def info(n) do
    case Model.description(n) do
      "" ->
        ""

      d ->
        ~s|<g class="info" data-info="#{n.id}" transform="translate(0 0)"><title>#{Fmt.esc(d)}</title><circle r="9"/><text y="4" text-anchor="middle" font-size="11" font-weight="700">i</text></g>|
    end
  end

  @doc "Everything that floats around a selected node: its data type and create-and-connect buttons."
  def pad(n), do: [if(Model.artifact?(n), do: "", else: type_pill(n)), create_buttons(n)] |> IO.iodata_to_binary()

  defp type_pill(n) do
    label = n.type_ref || "no type"
    w = 36 + round(String.length(label) * 7.2)

    ~s|<g class="tpill#{if n.type_ref == nil, do: " none"}" data-typepill="#{n.id}" transform="translate(0 -40)"><title>Data type: click to change</title><rect width="#{w}" height="24" rx="12"/><text x="12" y="16" font-size="11.5">#{Fmt.esc(label)}</text><path d="M#{w - 18} 10l4 4l4 -4" /></g>|
  end

  defp create_buttons(n) do
    case Model.pad_kinds(n.type) do
      [] ->
        ""

      kinds ->
        w = 8 + 30 * length(kinds)

        buttons =
          for {k, i} <- Enum.with_index(kinds) do
            ~s|<g class="mk" data-create="#{k}" transform="translate(#{19 + 30 * i} 16)"><title>Add #{@labels[k]}</title><rect class="hit" x="-15" y="-15" width="30" height="30" rx="8"/>#{@icons[k]}</g>|
          end

        ~s|<g class="pad" transform="translate(#{n.w + 38} #{div(n.h - 32, 2)})"><rect class="bg" width="#{w}" height="32" rx="16"/>#{buttons}</g>|
    end
  end

  # annotation: an open bracket on the left, the text beside it; the transparent box makes the whole area grabbable
  defp shape(%{type: :annotation} = n),
    do:
      ~s|<rect class="hitbox" width="#{n.w}" height="#{n.h}"/><path class="shape annotation" d="M12 1H1V#{n.h - 1}H12" fill="none"/>|

  # knowledge source: a rectangle with a wavy bottom edge
  defp shape(%{type: :source} = n) do
    {w, h} = {n.w, n.h}

    d =
      "M0 0H#{w}V#{h - 8}C#{w * 0.75} #{h - 18} #{w * 0.75} #{h + 2} #{w * 0.5} #{h - 8}S#{w * 0.25} #{h - 18} 0 #{h - 8}Z"

    ~s|<path class="shape source" d="#{d}" stroke-linejoin="round"/>|
  end

  # group: a dashed frame; only its border and title band can be grabbed, so what is inside stays reachable
  defp shape(%{type: :group} = n),
    do:
      ~s|<rect class="frame" x="0" y="0" width="#{n.w}" height="#{n.h}" rx="12"/><rect class="shape group" width="#{n.w}" height="#{n.h}" rx="12"/><rect class="band" width="#{n.w}" height="28" rx="12"/>|

  defp shape(%{type: :decision} = n), do: ~s|<rect class="shape decision" width="#{n.w}" height="#{n.h}" rx="5"/>|

  defp shape(%{type: :input} = n),
    do: ~s|<rect class="shape input" width="#{n.w}" height="#{n.h}" rx="#{div(n.h, 2)}"/>|

  # business knowledge (DMN notation): a rectangle with the top-left and bottom-right corners cut
  defp shape(%{type: :bkm} = n) do
    c = 14
    pts = [{c, 0}, {n.w, 0}, {n.w, n.h - c}, {n.w - c, n.h}, {0, n.h}, {0, c}]

    ~s|<polygon class="shape bkm" points="#{Enum.map_join(pts, " ", fn {x, y} -> "#{x},#{y}" end)}" stroke-linejoin="round"/>|
  end
end
