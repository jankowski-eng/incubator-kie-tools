defmodule DmnSpike.Autocomplete do
  @moduledoc "Name completion for a FEEL cell, from the DRD scope and a few built-ins."

  alias DmnSpike.{Fmt, Model}

  @builtins ~w(sum count min max mean abs floor ceiling round string length contains substring date time duration now today not)

  @doc """
  Splits `text` at the browser's cursor offset. The browser counts UTF-16 code units, so a character
  outside the Basic Multilingual Plane (an emoji) counts as two; Elixir's `String.slice/3` counts
  whole characters and would end up one position too far for every such character before the cursor.
  """
  def split_utf16(text, units) do
    {taken, _} =
      text
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, fn cp, {acc, n} ->
        if n >= units, do: {:halt, {acc, n}}, else: {:cont, {[cp | acc], n + utf16_units(cp)}}
      end)

    prefix = taken |> Enum.reverse() |> Enum.join()
    {prefix, binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix))}
  end

  @doc "Length of `text` in UTF-16 code units, the unit `setSelectionRange` expects."
  def utf16_length(text), do: text |> String.codepoints() |> Enum.reduce(0, &(utf16_units(&1) + &2))

  defp utf16_units(<<cp::utf8>>) when cp > 0xFFFF, do: 2
  defp utf16_units(_), do: 1

  @doc "Returns `{start_byte, names}` for the word ending at `caret` (a UTF-16 offset)."
  def suggest(%Model{} = m, id, idx, text, caret) do
    {before, _} = split_utf16(text, caret)

    case Regex.run(~r/[A-Za-z_][\w ]*$/u, before) do
      [run] ->
        names = Enum.uniq(Model.scope_names(m, id, idx) ++ @builtins)
        words = String.split(run, " ")

        Enum.find_value(0..(length(words) - 1), {byte_size(before), []}, fn i ->
          prefix = words |> Enum.drop(i) |> Enum.join(" ")

          found =
            Enum.filter(names, fn n ->
              prefix != "" and String.starts_with?(String.downcase(n), String.downcase(prefix)) and
                String.length(n) > String.length(prefix)
            end)

          if found != [], do: {byte_size(before) - byte_size(prefix), found |> Enum.take(6)}
        end)

      _ ->
        {byte_size(before), []}
    end
  end

  def list_html(_cell, []), do: ""

  def list_html(cell, names) do
    items =
      names
      |> Enum.with_index()
      |> Enum.map(fn {n, i} -> ~s|<li data-pick="#{i}" data-cell="#{cell}">#{Fmt.esc(n)}</li>| end)

    "<ul>#{items}</ul>"
  end

  @doc "The text after accepting suggestion `pick`, and the new caret as a UTF-16 offset."
  def accept(text, caret, start, names, pick) do
    name = Enum.at(names, pick)
    before = binary_part(text, 0, start)
    {_, after_caret} = split_utf16(text, caret)
    {before <> name <> after_caret, utf16_length(before <> name)}
  end
end
