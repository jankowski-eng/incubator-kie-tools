defmodule DmnSpike.Fmt do
  @moduledoc "Escaping and value formatting."

  def esc(s), do: s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")

  def value(nil), do: "null"
  def value(%Decimal{} = d), do: d |> Decimal.round(4) |> Decimal.normalize() |> Decimal.to_string(:normal)
  def value(v) when is_binary(v), do: inspect(v)
  def value(v) when is_boolean(v), do: to_string(v)
  def value(%Feel.Value.Function{params: params}), do: "ƒ(" <> Enum.map_join(params, ", ", &elem(&1, 0)) <> ")"

  def value(v) when is_map(v) and not is_struct(v),
    do: "{" <> Enum.map_join(Enum.sort(v), ", ", fn {k, x} -> "#{k}: #{value(x)}" end) <> "}"

  def value(v) when is_list(v), do: "[" <> Enum.map_join(v, ", ", &value/1) <> "]"
  def value(v), do: inspect(v, limit: 12, printable_limit: 60)

  def short(v, max \\ 18) do
    s = value(v)
    if String.length(s) > max, do: String.slice(s, 0, max - 1) <> "…", else: s
  end
end
