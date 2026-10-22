defmodule DmnSpike.Autocomplete do
  @moduledoc "Name completion for a FEEL cell, from the DRD scope and a few built-ins."

  alias DmnSpike.{Fmt, Model}

  @builtins ~w(sum count min max mean abs floor ceiling round string length contains substring date time duration now today not)

  @doc "Returns `{start_byte, names}` for the word ending at `caret`."
  def suggest(%Model{} = m, id, idx, text, caret) do
    before = String.slice(text, 0, caret)

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

  @doc "The text after accepting suggestion `pick`, and the new caret (in characters)."
  def accept(text, caret, start, names, pick) do
    name = Enum.at(names, pick)
    before = binary_part(text, 0, start)
    after_caret = String.slice(text, caret, String.length(text))
    {before <> name <> after_caret, String.length(before <> name)}
  end
end
