defmodule DmnSpike.XmlView do
  @moduledoc """
  The read-only XML source shown in the inspector. Takes the map from `Dmn.to_xml_map/2`.

  Highlighting is done per line, which is enough because the writer puts every tag on its own line. The lines come
  in chunks of 100 so the browser can skip the ones that are off screen (`content-visibility`), which keeps big
  models fluid. Each line shows its number, a fold marker when its element spans several lines, and the text; the
  text of the `.xc` elements joined by newlines is exactly the document, which is what Copy puts on the clipboard.
  """

  alias DmnSpike.Fmt

  @chunk 100
  @name "[\\w:.\\-]+"
  @decl Regex.compile!("^(\\s*)(<\\?.*\\?>)$")
  @close Regex.compile!("^(\\s*)</(#{@name})>$")
  @open Regex.compile!("^(\\s*)<(#{@name})((?:\\s+#{@name}=\"[^\"]*\")*)(/?)>(.*?)(?:</(#{@name})>)?$")
  @attr Regex.compile!("(#{@name})=\"([^\"]*)\"")

  def html(%{lines: lines, folds: folds}) do
    fold_to = Map.new(folds)

    lines
    |> Enum.with_index(1)
    |> Enum.chunk_every(@chunk)
    |> Enum.map(fn chunk ->
      [~s|<div class="xchunk">|, Enum.map(chunk, fn {l, n} -> line(l, n, fold_to[n]) end), "</div>"]
    end)
    |> IO.iodata_to_binary()
  end

  defp line(text, n, fold_to) do
    gutter =
      if fold_to,
        do:
          ~s|<span class="xg" data-to="#{fold_to}" title="Fold"><svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 4.5 6 8l3.5-3.5"/></svg></span>|,
        else: ~s|<span class="xg"></span>|

    ~s|<div class="xl" data-n="#{n}"><span class="xn">#{n}</span>#{gutter}<span class="xc">#{highlight(text)}</span></div>|
  end

  @doc "The HTML of one line of XML: same characters as `text`, wrapped in token spans."
  def highlight(text) do
    cond do
      m = Regex.run(@decl, text) -> [pad(Enum.at(m, 1)), span("xd", Enum.at(m, 2))]
      m = Regex.run(@close, text) -> [pad(Enum.at(m, 1)), span("xp", "</"), span("xt", Enum.at(m, 2)), span("xp", ">")]
      m = Regex.run(@open, text) -> open_tag(m)
      true -> Fmt.esc(text)
    end
    |> IO.iodata_to_binary()
  end

  defp open_tag([_, pad, name, attrs, slash, body | rest]) do
    closing =
      case rest do
        [c] when c != "" -> [span("xp", "</"), span("xt", c), span("xp", ">")]
        _ -> []
      end

    [
      pad(pad),
      span("xp", "<"),
      span("xt", name),
      attributes(attrs),
      span("xp", slash <> ">"),
      if(body == "", do: "", else: span("xx", body)),
      closing
    ]
  end

  defp attributes(""), do: ""

  # the attribute text is `( name="value")*`: keep the blanks between them as they are
  defp attributes(attrs) do
    Regex.split(@attr, attrs, include_captures: true)
    |> Enum.map(fn piece ->
      case Regex.run(@attr, piece) do
        [^piece, name, value] -> [span("xa", name), span("xp", "=\""), span("xv", value), span("xp", "\"")]
        _ -> Fmt.esc(piece)
      end
    end)
  end

  defp pad(p), do: Fmt.esc(p)
  defp span(class, text), do: ~s|<span class="#{class}">#{Fmt.esc(text)}</span>|

  # --- where things are ----------------------------------------------------------------

  @doc "The lines `{from, to}` of the element for `key` (its model element, not its diagram shape), or nil."
  def range(%{ranges: ranges}, key) do
    case Enum.find(ranges, fn {_, _, k} -> k == key end) do
      {from, to, _} -> {from, to}
      nil -> nil
    end
  end

  @doc "The key of the most specific element that contains `line`, or nil when it is outside every element with a visual counterpart."
  def key_at(%{ranges: ranges}, line) do
    ranges
    |> Enum.filter(fn {from, to, _} -> line >= from and line <= to end)
    |> Enum.min_by(fn {from, to, _} -> to - from end, fn -> nil end)
    |> case do
      {_, _, key} -> key
      nil -> nil
    end
  end
end
