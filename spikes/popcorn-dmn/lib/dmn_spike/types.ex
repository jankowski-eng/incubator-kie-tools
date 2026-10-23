defmodule DmnSpike.Types do
  @moduledoc """
  Data types as in KIE's DMN editor: item definitions with a built-in or custom
  `ref` (nil = structure with `components`), `collection`, and a typeConstraint
  of kind enumeration, range or expression (all FEEL unary tests).
  """

  alias DmnSpike.Model

  @builtins [
    "Any",
    "boolean",
    "context",
    "date",
    "date and time",
    "days and time duration",
    "number",
    "string",
    "time",
    "years and months duration"
  ]
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
      scalar("tVerdict", "string", {:enumeration, ~s|"Qualified", "Not qualified"|}),
      scalar("tCategory", "string", {:enumeration, ~s|"Low", "Medium", "High"|})
    ]
  end

  defp scalar(name, ref, constraint),
    do: %{
      name: name,
      ref: ref,
      collection: false,
      components: [],
      constraint: constraint && %{kind: elem(constraint, 0), text: elem(constraint, 1)}
    }

  defp struct_type(name, components),
    do: %{name: name, ref: nil, collection: false, constraint: nil, components: components}

  # --- lookup -----------------------------------------------------------------

  # A top-level type being renamed to a name that is not acceptable yet (empty, or taken) keeps the name its
  # references use in `:committed`; lookups go by that name until a valid one is typed.
  defp effective(t), do: Map.get(t, :committed, t.name)

  def find(%Model{types: types}, name), do: Enum.find(types, &(effective(&1) == name))

  # --- validation ---------------------------------------------------------------

  @doc "Errors (strings) for `value` against the type named `ref`; [] when it conforms."
  def validate(_m, nil, _ref), do: []
  def validate(_m, _value, ref) when ref in [nil, "", "<Undefined>", "Any"], do: []

  def validate(%Model{} = m, value, ref) do
    cond do
      ref in @builtins -> check_builtin(ref, value)
      t = find(m, ref) -> check(m, value, t, [t.name])
      true -> ["unknown type #{ref}"]
    end
  end

  defp check(_m, nil, _t, _seen), do: []

  # An expression constraint on a list constrains the whole list (as `typeConstraint` does in KIE's editor);
  # an enumeration or range is checked against every item.
  defp check(m, value, %{collection: true} = t, seen) when is_list(value) do
    {item, whole} =
      if match?(%{kind: :expression}, t.constraint),
        do: {%{t | collection: false, constraint: nil}, t.constraint},
        else: {%{t | collection: false}, nil}

    case Enum.flat_map(value, &check(m, &1, item, seen)) do
      [] -> check_constraint(whole, value)
      errors -> errors
    end
  end

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
  defp check_builtin("context", v) when is_map(v) and not is_struct(v), do: []
  defp check_builtin("context", _), do: ["expected a context"]
  defp check_builtin("date", %Date{}), do: []
  defp check_builtin("date", _), do: ["expected a date"]
  defp check_builtin("time", %Feel.Value.Time{}), do: []
  defp check_builtin("time", _), do: ["expected a time"]
  defp check_builtin("date and time", %Feel.Value.DateTime{}), do: []
  defp check_builtin("date and time", _), do: ["expected a date and time"]
  defp check_builtin("days and time duration", %Feel.Value.DaysAndTimeDuration{}), do: []
  defp check_builtin("days and time duration", _), do: ["expected a days and time duration"]
  defp check_builtin("years and months duration", %Feel.Value.YearsAndMonthsDuration{}), do: []
  defp check_builtin("years and months duration", _), do: ["expected a years and months duration"]
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

  # --- checks for the editor ------------------------------------------------------

  @doc "The type or component at `path`, or nil when the path no longer exists (the model changed under a selection)."
  def fetch(types, [i]), do: Enum.at(types, i)

  def fetch(types, [i | rest]) do
    case Enum.at(types, i) do
      nil -> nil
      t -> fetch(t.components, rest)
    end
  end

  def siblings(types, [_]), do: types
  def siblings(types, path), do: types |> fetch(Enum.drop(path, -1)) |> Map.fetch!(:components)

  @doc "Why the name at `path` is not acceptable, or nil."
  def name_error(types, path) do
    t = fetch(types, path)
    own = List.last(path)

    cond do
      String.trim(t.name) == "" ->
        "A name is required"

      Enum.any?(Enum.with_index(siblings(types, path)), fn {x, i} -> i != own and x.name == t.name end) ->
        "\"#{t.name}\" is already used here"

      true ->
        nil
    end
  end

  @doc "Why the type reference of `t` does not resolve, or nil."
  def ref_error(_m, %{ref: ref}) when ref in [nil, ""], do: nil

  def ref_error(%Model{} = m, %{ref: ref}),
    do: if(ref in @builtins or find(m, ref), do: nil, else: "Unknown type \"#{ref}\"")

  @doc "Every problem to show for the item at `path`."
  def errors(%Model{} = m, path) do
    t = fetch(m.types, path)
    c = constraint_error(t.constraint)
    Enum.reject([name_error(m.types, path), ref_error(m, t), c && c.message], &is_nil/1)
  end

  @doc "The built-in type a type resolves to (following references), or nil for a structure."
  def base(%Model{} = m, %{ref: ref}, depth \\ 0) do
    cond do
      depth > 10 or ref in [nil, ""] -> nil
      ref in @builtins -> ref
      t = find(m, ref) -> base(m, t, depth + 1)
      true -> nil
    end
  end

  @doc "Where the top-level type `name` is used: `%{nodes: [names], types: [\"Type\" or \"Type.field\"]}`."
  def usages(%Model{} = m, name) do
    name = ((t = Enum.find(m.types, &(&1.name == name))) && effective(t)) || name
    nodes = for {_, n} <- m.nodes, n.type_ref == name, do: n.name

    # a decision table's columns have a type too
    columns =
      for {_, %{expr: %{kind: :table} = e} = n} <- m.nodes,
          {label, cols} <- [{"input", e.inputs}, {"output", e.outputs}],
          {c, i} <- Enum.with_index(cols, 1),
          Map.get(c, :type_ref) == name,
          do: "#{n.name} (#{label} column #{i})"

    %{nodes: Enum.sort(nodes ++ columns), types: for(t <- m.types, label <- refs_in(t, t.name, name), do: label)}
  end

  defp refs_in(t, label, name) do
    own = if t.ref == name and label != name, do: [label], else: []
    own ++ Enum.flat_map(t.components, &refs_in(&1, label <> "." <> &1.name, name))
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

  @doc """
  Renames the top-level type at index `i`. References (nodes, table columns, other types) follow only once
  the name is acceptable, so typing a name that is taken for a moment does not merge the references of two
  types: until then the type keeps the name its references use (`:committed`).
  """
  def rename_top(%Model{} = m, i, new) do
    t = Enum.at(m.types, i)
    from = effective(t)
    others = List.delete_at(m.types, i)

    if String.trim(new) == "" or Enum.any?(others, &(&1.name == new or effective(&1) == new)) do
      %{m | types: List.replace_at(m.types, i, t |> Map.put(:name, new) |> Map.put(:committed, from))}
    else
      m = rename_refs(m, from, new)
      %{m | types: List.update_at(m.types, i, &(&1 |> Map.put(:name, new) |> Map.delete(:committed)))}
    end
  end

  @doc "Points every reference to `old` at `new` (the type definition itself is untouched)."
  def rename_refs(%Model{} = m, old, new) when old != new do
    types = rename_in(m.types, old, new)
    nodes = Map.new(m.nodes, fn {id, n} -> {id, rename_node(n, old, new)} end)
    %{m | types: types, nodes: nodes}
  end

  def rename_refs(m, _, _), do: m

  # a node's own type and the types of a decision table's columns
  defp rename_node(n, old, new) do
    n = if n.type_ref == old, do: %{n | type_ref: new}, else: n
    swap = fn col -> if Map.get(col, :type_ref) == old, do: Map.put(col, :type_ref, new), else: col end

    case n.expr do
      %{kind: :table, inputs: ins, outputs: outs} = e ->
        %{n | expr: %{e | inputs: Enum.map(ins, swap), outputs: Enum.map(outs, swap)}}

      _ ->
        n
    end
  end

  defp rename_in(types, old, new) do
    Enum.map(types, fn t ->
      %{t | ref: if(t.ref == old, do: new, else: t.ref), components: rename_in(t.components, old, new)}
    end)
  end
end
