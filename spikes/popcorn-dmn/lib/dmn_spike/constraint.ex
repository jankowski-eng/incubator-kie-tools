defmodule DmnSpike.Constraint do
  @moduledoc """
  The visual forms of a type constraint (comparison, interval, list of values) and their FEEL text.

  `parse/2` only recognises text that the visual editors can reproduce exactly; anything else is `:advanced`
  and stays untouched until the user edits it as FEEL. `build/1` writes the canonical text of a visual form.
  """

  @num "-?\\d+(?:\\.\\d+)?"
  @str "\"(?:[^\"\\\\]|\\\\.)*\""
  @cmp Regex.compile!("^(<=|>=|<|>)\\s*(#{@num})$")
  @interval Regex.compile!("^([\\[\\(])\\s*(#{@num})\\s*\\.\\.\\s*(#{@num})\\s*([\\]\\)])$")
  @item Regex.compile!("^\\s*(#{@num}|#{@str})\\s*(?:,|$)")

  @type t ::
          {:cmp, String.t(), String.t()}
          | {:interval, String.t(), String.t(), String.t(), String.t()}
          | {:list, [String.t()]}
          | :advanced

  @doc "Reads `text`; `kind` (`:enumeration`, `:range`, `:expression`) decides how a lone literal is understood."
  @spec parse(String.t(), atom) :: t
  def parse(text, kind \\ :expression) do
    text = String.trim(text || "")

    cond do
      text == "" -> {:list, []}
      m = Regex.run(@cmp, text) -> {:cmp, Enum.at(m, 1), Enum.at(m, 2)}
      m = Regex.run(@interval, text) -> {:interval, Enum.at(m, 1), Enum.at(m, 2), Enum.at(m, 3), Enum.at(m, 4)}
      true -> as_list(text, kind)
    end
  end

  defp as_list(_text, :range), do: :advanced

  defp as_list(text, _kind) do
    case list(text, []) do
      :error -> :advanced
      items -> {:list, items}
    end
  end

  @doc "The kind a visual form is stored as."
  def kind({:list, _}), do: :enumeration
  def kind(_), do: :range

  def build({:cmp, op, lit}), do: "#{op} #{lit}"
  def build({:interval, lo, a, b, hi}), do: "#{lo}#{a}..#{b}#{hi}"
  def build({:list, items}), do: Enum.join(items, ", ")

  @doc "Wraps `raw` as a FEEL literal for a type whose base is `base`: strings get quotes, everything else is kept."
  def literal("string", raw) do
    raw = String.trim(raw)

    if Regex.match?(Regex.compile!("^#{@str}$"), raw),
      do: raw,
      else: ~s|"#{raw |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}"|
  end

  def literal(_base, raw), do: String.trim(raw)

  defp list("", [_ | _] = acc), do: Enum.reverse(acc)
  defp list("", []), do: :error

  defp list(text, acc) do
    case Regex.run(@item, text) do
      [whole, item] -> list(binary_part(text, byte_size(whole), byte_size(text) - byte_size(whole)), [item | acc])
      _ -> :error
    end
  end
end
