defmodule DmnSpike.Types do
  @moduledoc """
  Data types as in KIE's DMN editor: item definitions with a built-in or custom
  `ref` (nil = structure with `components`), `collection`, and a typeConstraint
  of kind enumeration, range or expression (all FEEL unary tests).
  """

  alias DmnSpike.Model

  @builtins ["Any", "boolean", "context", "date", "date and time", "days and time duration", "number", "string", "time", "years and months duration"]
  @kinds [:enumeration, :range, :expression]

  def builtins, do: @builtins
  def kinds, do: @kinds

  def new_type(name \\ "New data type"),
    do: %{name: name, ref: "string", collection: false, constraint: nil, components: []}

  def sample do
    [
      struct_type("tApplicant", [
        scalar("Income", "number", {:range, ">= 0"}),
        scalar("Tax", "number", {:range, ">= 0"}),
        scalar("Insurance", "number", nil),
        scalar("Debt", "number", {:range, ">= 0"})
      ]),
      struct_type("tRequested", [
        scalar("Amount", "number", {:range, "> 0"}),
        scalar("Rate", "number", {:range, "(0..20]"}),
        scalar("Term", "number", {:enumeration, "120, 180, 240, 360"})
      ]),
      scalar("tRatio", "number", {:range, "[0..100]"}),
      scalar("tVerdict", "string", {:enumeration, ~s|"Qualified", "Not qualified"|})
    ]
  end

  defp scalar(name, ref, constraint),
    do: %{name: name, ref: ref, collection: false, components: [], constraint: constraint && %{kind: elem(constraint, 0), text: elem(constraint, 1)}}

  defp struct_type(name, components), do: %{name: name, ref: nil, collection: false, constraint: nil, components: components}

  # --- lookup -----------------------------------------------------------------

  def find(%Model{types: types}, name), do: Enum.find(types, &(&1.name == name))

  # --- validation ---------------------------------------------------------------

  @doc "Errors (strings) for `value` against the type named `ref`; [] when it conforms."
  def validate(_m, _value, ref) when ref in [nil, "", "<Undefined>", "Any"], do: []

  def validate(%Model{} = m, value, ref) do
    cond do
      ref in @builtins -> check_builtin(ref, value)
      t = find(m, ref) -> check(m, value, t, [t.name])
      true -> ["unknown type #{ref}"]
    end
  end

  defp check(_m, nil, _t, _seen), do: []

  defp check(m, value, %{collection: true} = t, seen) when is_list(value),
    do: value |> Enum.flat_map(&check(m, &1, %{t | collection: false}, seen))

  defp check(_m, _value, %{collection: true}, _seen), do: ["expected a list"]

  defp check(m, value, t, seen) do
    base =
      cond do
        t.ref == nil -> check_struct(m, value, t, seen)
        t.ref in @builtins -> check_builtin(t.ref, value)
        t.ref in seen -> ["type #{t.ref} refers to itself"]
        other = find(m, t.ref) -> check(m, value, other, [t.ref | seen])
        true -> ["unknown type #{t.ref}"]
      end

    if base == [], do: check_constraint(t.constraint, value), else: base
  end

  defp check_struct(m, value, t, seen) when is_map(value) and not is_struct(value) do
    Enum.flat_map(t.components, fn c ->
      check(m, Map.get(value, c.name), c, seen) |> Enum.map(&"#{c.name}: #{&1}")
    end)
  end

  defp check_struct(_m, _value, _t, _seen), do: ["expected a structure"]

  defp check_builtin("number", %Decimal{}), do: []
  defp check_builtin("number", _), do: ["expected a number"]
  defp check_builtin("string", v) when is_binary(v), do: []
  defp check_builtin("string", _), do: ["expected a string"]
  defp check_builtin("boolean", v) when is_boolean(v), do: []
  defp check_builtin("boolean", _), do: ["expected a boolean"]
  defp check_builtin("context", v) when is_map(v), do: []
  defp check_builtin("context", _), do: ["expected a context"]
  defp check_builtin("date", %Date{}), do: []
  defp check_builtin("date", _), do: ["expected a date"]
  defp check_builtin("time", %Time{}), do: []
  defp check_builtin("time", _), do: ["expected a time"]
  defp check_builtin(_other, _value), do: []

  defp check_constraint(nil, _), do: []
  defp check_constraint(%{text: text}, _) when text in [nil, ""], do: []

  defp check_constraint(%{text: text}, value) do
    with {:ok, prepared} <- Feel.prepare(text, entry: :unary_tests, sandbox: false),
         {:ok, ok?, _} <- Feel.test(prepared, value, %{}, sandbox: false) do
      if ok? == false, do: ["violates constraint #{text}"], else: []
    else
      _ -> ["invalid constraint #{text}"]
    end
  end

  @doc "`nil` when the constraint text is a valid list of unary tests, else the FEEL error."
  def constraint_error(nil), do: nil
  def constraint_error(%{text: text}) when text in [nil, ""], do: nil

  def constraint_error(%{text: text}) do
    case Feel.prepare(text, entry: :unary_tests, sandbox: false) do
      {:ok, _} -> nil
      {:error, e} -> e
    end
  end

  # --- path edits (a path is a list of indexes through components) ----------------

  def get(types, [i]), do: Enum.at(types, i)
  def get(types, [i | rest]), do: types |> Enum.at(i) |> Map.fetch!(:components) |> get(rest)

  def update(types, [i], fun), do: List.update_at(types, i, fun)

  def update(types, [i | rest], fun),
    do: List.update_at(types, i, fn t -> %{t | components: update(t.components, rest, fun)} end)

  def delete(types, [i]), do: List.delete_at(types, i)

  def delete(types, [i | rest]),
    do: List.update_at(types, i, fn t -> %{t | components: delete(t.components, rest)} end)

  def add_child(types, path, child),
    do: update(types, path, fn t -> %{t | ref: nil, components: t.components ++ [child]} end)

  @doc "Renames the top-level type at index `i` and every reference to it."
  def rename_top(%Model{} = m, i, new) do
    old = Enum.at(m.types, i).name
    m = rename_refs(m, old, new)
    %{m | types: List.update_at(m.types, i, &%{&1 | name: new})}
  end

  @doc "Points every reference to `old` at `new` (the type definition itself is untouched)."
  def rename_refs(%Model{} = m, old, new) when old != new do
    types = rename_in(m.types, old, new)
    nodes = Map.new(m.nodes, fn {id, n} -> {id, if(n.type_ref == old, do: %{n | type_ref: new}, else: n)} end)
    %{m | types: types, nodes: nodes}
  end

  def rename_refs(m, _, _), do: m

  defp rename_in(types, old, new) do
    Enum.map(types, fn t ->
      %{t | ref: if(t.ref == old, do: new, else: t.ref), components: rename_in(t.components, old, new)}
    end)
  end
end
