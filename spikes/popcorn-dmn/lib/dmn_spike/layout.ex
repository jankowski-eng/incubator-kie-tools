defmodule DmnSpike.Layout do
  @moduledoc """
  Layered auto-layout. Nodes nothing depends on go to the top; their
  requirements sit in the layers below. Order inside a layer comes from a few
  barycenter sweeps to reduce crossings; layers are centred on each other.
  """

  alias DmnSpike.Model

  @gap_x 40
  @gap_y 70
  @margin 30

  @doc """
  Lays out the decision graph. Annotations and sources follow the node they are linked to; groups stay
  where they are (move them by hand).
  """
  def run(%Model{} = m) do
    {drg, rest} = m.nodes |> Map.split_with(fn {_, n} -> not Model.artifact?(n) end)
    laid = layout(%{m | nodes: drg})

    moved =
      for {id, n} <- rest, n.type != :group, into: %{} do
        {other, dx, dy} =
          Enum.find_value(m.links, {nil, 0, 0}, fn {a, b, _} ->
            o = if a == id, do: b, else: if(b == id, do: a, else: nil)
            if o && drg[o], do: {o, laid.nodes[o].x - drg[o].x, laid.nodes[o].y - drg[o].y}
          end)

        {id, if(other, do: %{n | x: n.x + dx, y: n.y + dy}, else: n)}
      end

    %{laid | nodes: laid.nodes |> Map.merge(rest) |> Map.merge(moved)}
  end

  defp layout(%Model{nodes: nodes} = m) when map_size(nodes) == 0, do: m

  defp layout(%Model{} = m) do
    layer = layers(m)
    by_layer = layer |> Enum.group_by(fn {_, l} -> l end, fn {id, _} -> id end)
    depth = by_layer |> Map.keys() |> Enum.max()

    initial =
      Map.new(by_layer, fn {l, ids} -> {l, Enum.sort_by(ids, &{m.nodes[&1].x, &1})} end)

    order =
      Enum.reduce(1..4, initial, fn _, acc ->
        sweep(m, sweep(m, acc, 1..depth//1, :above), (depth - 1)..0//-1, :below)
      end)

    width = fn ids -> Enum.sum(for id <- ids, do: m.nodes[id].w) + @gap_x * (length(ids) - 1) end
    widest = order |> Map.values() |> Enum.map(width) |> Enum.max()
    row_h = m.nodes |> Map.values() |> Enum.map(& &1.h) |> Enum.max()

    nodes =
      for {l, ids} <- order, reduce: m.nodes do
        acc ->
          start = @margin + div(widest - width.(ids), 2)

          {acc, _} =
            Enum.reduce(ids, {acc, start}, fn id, {a, x} ->
              n = a[id]
              {Map.put(a, id, %{n | x: x, y: @margin + l * (row_h + @gap_y)}), x + n.w + @gap_x}
            end)

          acc
      end

    %{m | nodes: nodes}
  end

  @doc "layer 0 = required by nobody; otherwise 1 + the deepest layer among its dependents."
  def layers(%Model{} = m) do
    Enum.reduce(Map.keys(m.nodes), %{}, fn id, acc -> elem(layer_of(m, id, acc, []), 1) end)
  end

  defp layer_of(m, id, acc, stack) do
    cond do
      Map.has_key?(acc, id) ->
        {acc[id], acc}

      id in stack ->
        {0, acc}

      true ->
        tos = for {^id, to, _} <- m.edges, do: to

        {l, acc} =
          Enum.reduce(tos, {-1, acc}, fn to, {best, acc} ->
            {l, acc} = layer_of(m, to, acc, [id | stack])
            {max(best, l), acc}
          end)

        {l + 1, Map.put(acc, id, l + 1)}
    end
  end

  # reorder layers in `range` by the mean index of neighbours in the adjacent layer
  defp sweep(m, order, range, dir) do
    Enum.reduce(range, order, fn l, acc ->
      ref_layer = if dir == :above, do: l - 1, else: l + 1
      ref_pos = acc |> Map.get(ref_layer, []) |> Enum.with_index() |> Map.new()

      ordered =
        acc[l]
        |> Enum.with_index()
        |> Enum.sort_by(fn {id, i} ->
          neigh =
            for {a, b, _} <- m.edges,
                n <- [if(dir == :above, do: if(a == id, do: b), else: if(b == id, do: a))],
                n != nil,
                Map.has_key?(ref_pos, n),
                do: ref_pos[n]

          {if(neigh == [], do: i * 1.0, else: Enum.sum(neigh) / length(neigh)), i}
        end)
        |> Enum.map(&elem(&1, 0))

      Map.put(acc, l, ordered)
    end)
  end
end
