defmodule DmnSpike.Highlight do
  @moduledoc """
  FEEL syntax highlighting built on `Feel.Syntax.Lexer` (byte spans) and the
  error span of `Feel.parse/1`/evaluation. Returns HTML that must have exactly
  the same text as the input so it can sit under a transparent textarea.
  """

  alias DmnSpike.Fmt
  alias Feel.Syntax.Lexer

  @doc "HTML for `text`; `err` is a `{from, to}` byte span or nil."
  def html(text, err \\ nil) do
    case Lexer.tokenize(text) do
      {:ok, tokens} -> segments(text, tokens, 0, err, []) |> IO.iodata_to_binary()
      {:error, [%{span: span} | _]} -> plain(text, err || span)
    end
  end

  defp segments(text, [], pos, err, acc) do
    rest = binary_part(text, pos, byte_size(text) - pos)
    tail = if err && elem(err, 0) >= byte_size(text), do: [~s|<span class="err eof"></span>|], else: []
    Enum.reverse([tail, gap(rest) | acc])
  end

  defp segments(text, [%{span: {from, to}} = t | rest], pos, err, acc) do
    g = gap(binary_part(text, pos, from - pos))
    seg = span(class(t, rest), binary_part(text, from, to - from), overlaps?(err, from, to))
    segments(text, rest, to, err, [seg, g | acc])
  end

  defp gap(""), do: ""
  defp gap(g), do: if(String.contains?(g, ["//", "/*"]), do: ~s|<span class="c">#{Fmt.esc(g)}</span>|, else: Fmt.esc(g))

  defp span(class, text, err?), do: ~s|<span class="#{class}#{if err?, do: " err"}">#{Fmt.esc(text)}</span>|

  defp plain(text, {from, to}) do
    from = min(from, byte_size(text))
    to = min(max(to, from), byte_size(text))

    [
      Fmt.esc(binary_part(text, 0, from)),
      ~s|<span class="err">#{Fmt.esc(binary_part(text, from, to - from))}</span>|,
      Fmt.esc(binary_part(text, to, byte_size(text) - to))
    ]
    |> IO.iodata_to_binary()
  end

  defp overlaps?(nil, _, _), do: false
  defp overlaps?({a, b}, from, to), do: if(a == b, do: false, else: a < to and b > from)

  defp class(%{kind: :number}, _), do: "n"
  defp class(%{kind: :string}, _), do: "s"
  defp class(%{kind: :word, keyword?: true}, _), do: "k"
  defp class(%{kind: kind}, [%{text: "("} | _]) when kind in [:word, :quoted_name], do: "fn"
  defp class(%{kind: kind}, _) when kind in [:word, :quoted_name], do: "id"
  defp class(_, _), do: "op"
end
