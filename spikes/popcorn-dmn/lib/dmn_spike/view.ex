defmodule DmnSpike.View do
  @moduledoc "Pan and zoom as pure functions over an SVG viewBox `{x, y, w, h}`."

  @min_w 80.0
  @max_w 200_000.0

  @doc "Zooms by factor `f` (< 1 zooms in) keeping the point `{px, py}` fixed on screen."
  def zoom({x, y, w, h}, f, px, py) do
    nw = min(max(w * f, @min_w), @max_w)
    f = nw / w
    {px - (px - x) * f, py - (py - y) * f, nw, h * f}
  end

  def pan({x, y, w, h}, dx, dy), do: {x + dx, y + dy, w, h}

  def center({x, y, w, h}), do: {x + w / 2, y + h / 2}

  def to_string({x, y, w, h}), do: Enum.map_join([x, y, w, h], " ", &fmt/1)

  defp fmt(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)

  def parse(str) do
    [x, y, w, h] = str |> String.split(" ") |> Enum.map(&(&1 |> Float.parse() |> elem(0)))
    {x, y, w, h}
  end
end
