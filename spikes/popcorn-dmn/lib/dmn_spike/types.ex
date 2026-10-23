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

  def find(%Model{types: types, ext_types: ext}, name),
    do: Enum.find(types, &(effective(&1) == name)) || Enum.find(ext, &(&1.name == name))

  @doc """
  The types of the model imported as `import_name`, named the way a document that imports it refers to them
  (`import_name.Type`), and their references with them (`lohn.Status!`, `list<lohn.Status>`).
  """
  def external(import_name, types) do
    prefix = fn ref ->
      map_ref(ref, fn name -> if name in @builtins, do: name, else: import_name <> "." <> name end)
    end

    walk = fn walk, t ->
      %{t | ref: prefix.(t.ref), components: Enum.map(t.components, &walk.(walk, &1))}
    end

    for t <- types, do: %{walk.(walk, t) | name: import_name <> "." <> t.name}
  end

  # --- type references ------------------------------------------------------------------

  @doc """
  A type reference as FEEL writes a type: a name (`number`, `tApplicant`), `list<reference>`, and a trailing `!`
  for "not null" on either (`number!`, `list<string!>!`). `{:ok, {:type, name, not_null?}}`,
  `{:ok, {:list, inner, not_null?}}`, or `:error`.
  """
  def parse_ref(ref) when is_binary(ref) do
    ref = String.trim(ref)
    {body, not_null} = if String.ends_with?(ref, "!"), do: {String.slice(ref, 0..-2//1), true}, else: {ref, false}
    body = String.trim(body)

    cond do
      body == "" ->
        :error

      String.starts_with?(body, "list<") and String.ends_with?(body, ">") ->
        with {:ok, inner} <- body |> String.slice(5..-2//1) |> parse_ref(), do: {:ok, {:list, inner, not_null}}

      true ->
        {:ok, {:type, body, not_null}}
    end
  end

  def parse_ref(_), do: :error

  defp format_ref({:type, name, not_null}), do: name <> if(not_null, do: "!", else: "")
  defp format_ref({:list, inner, not_null}), do: "list<" <> format_ref(inner) <> ">" <> if(not_null, do: "!", else: "")

  @doc "The type names a reference mentions (`list<Foo!>!` mentions `Foo`)."
  def ref_names(ref) do
    case parse_ref(ref) do
      {:ok, ast} -> ast_names(ast)
      :error -> []
    end
  end

  defp ast_names({:type, name, _}), do: [name]
  defp ast_names({:list, inner, _}), do: ast_names(inner)

  @doc "Whether `ref` mentions the type `name`."
  def refers?(ref, name), do: name in ref_names(ref)

  # `ref` with every name it mentions replaced by `fun.(name)`; what is not a reference is returned as it is
  defp map_ref(ref, _fun) when ref in [nil, ""], do: ref

  defp map_ref(ref, fun) do
    case parse_ref(ref) do
      {:ok, ast} -> ast |> map_ast(fun) |> format_ref()
      :error -> ref
    end
  end

  defp map_ast({:type, name, nn}, fun), do: {:type, fun.(name), nn}
  defp map_ast({:list, inner, nn}, fun), do: {:list, map_ast(inner, fun), nn}

  @doc """
  The references to choose from for a type or a node, as `[{group, [reference]}]`: the types, and the forms of
  each: not null (`T!`) and lists (`list<T>`, `list<T!>!`). Any other form can be written in a file and is kept.
  """
  def choices(%Model{} = m, hide \\ []) do
    custom = for t <- m.types ++ m.ext_types, t.name not in hide, do: t.name
    names = @builtins ++ custom

    [
      {"Built-in", @builtins},
      {"Custom", custom},
      {"Not null", for(n <- names, n != "Any", do: n <> "!")},
      {"List", Enum.flat_map(names, &["list<#{&1}>", "list<#{&1}!>!"])}
    ]
  end

  # --- validation ---------------------------------------------------------------

  @doc "Errors (strings) for `value` against the type reference `ref`; [] when it conforms."
  def validate(_m, _value, ref) when ref in [nil, "", "<Undefined>", "Any"], do: []
  def validate(%Model{} = m, value, ref), do: check_ref(m, value, ref, [])

  # a reference: a name that is built in or a type of the model, or a list of them, each possibly not null
  defp check_ref(m, value, ref, seen) do
    case parse_ref(ref) do
      {:ok, ast} -> check_ast(m, value, ast, seen)
      :error -> ["invalid type #{ref}"]
    end
  end

  defp check_ast(_m, nil, {_, _, true}, _seen), do: ["must not be null"]
  defp check_ast(_m, nil, _ast, _seen), do: []

  defp check_ast(m, value, {:list, inner, _}, seen) when is_list(value),
    do: Enum.flat_map(value, &check_ast(m, &1, inner, seen))

  defp check_ast(_m, _value, {:list, _, _}, _seen), do: ["expected a list"]

  defp check_ast(m, value, {:type, name, _}, seen) do
    cond do
      name in @builtins -> check_builtin(name, value)
      name in seen -> ["type #{name} refers to itself"]
      t = find(m, name) -> check(m, value, t, [name | seen])
      true -> ["unknown type #{name}"]
    end
  end

  # null is fine unless the type says `!`
  defp check(_m, nil, t, _seen),
    do: if(match?({:ok, {_, _, true}}, parse_ref(t.ref)), do: ["must not be null"], else: [])

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
        true -> check_ref(m, value, t.ref, seen)
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

      length(path) == 1 and t.name in @builtins ->
        "\"#{t.name}\" is a built-in type"

      Enum.any?(Enum.with_index(siblings(types, path)), fn {x, i} -> i != own and x.name == t.name end) ->
        "\"#{t.name}\" is already used here"

      true ->
        nil
    end
  end

  @doc "Why the type reference of `t` does not resolve, or nil."
  def ref_error(_m, %{ref: ref}) when ref in [nil, ""], do: nil

  def ref_error(%Model{} = m, %{ref: ref}) do
    case parse_ref(ref) do
      :error ->
        "Invalid type \"#{ref}\""

      {:ok, ast} ->
        case Enum.find(ast_names(ast), &(&1 not in @builtins and find(m, &1) == nil)) do
          nil -> nil
          name -> "Unknown type \"#{name}\""
        end
    end
  end

  @doc "Every problem to show for the item at `path`."
  def errors(%Model{} = m, path) do
    t = fetch(m.types, path)
    c = constraint_error(t.constraint)
    Enum.reject([name_error(m.types, path), ref_error(m, t), c && c.message], &is_nil/1)
  end

  @doc "The built-in type a type resolves to (following references), or nil for a structure."
  def base(%Model{} = m, %{ref: ref}, depth \\ 0) do
    with false <- depth > 10 or ref in [nil, ""],
         {:ok, ast} <- parse_ref(ref) do
      base_of(m, ast, depth)
    else
      _ -> nil
    end
  end

  # a list is as its items are
  defp base_of(m, {:list, inner, _}, depth), do: base_of(m, inner, depth)

  defp base_of(m, {:type, name, _}, depth) do
    cond do
      name in @builtins -> name
      t = find(m, name) -> base(m, t, depth + 1)
      true -> nil
    end
  end

  @doc "Where the top-level type `name` is used: `%{nodes: [names], types: [\"Type\" or \"Type.field\"]}`."
  def usages(%Model{} = m, name) do
    name = ((t = Enum.find(m.types, &(&1.name == name))) && effective(t)) || name
    nodes = for {_, n} <- m.nodes, refers?(n.type_ref, name), do: n.name

    # a decision table's columns have a type too
    columns =
      for {_, %{expr: %{kind: :table} = e} = n} <- m.nodes,
          {label, cols} <- [{"input", e.inputs}, {"output", e.outputs}],
          {c, i} <- Enum.with_index(cols, 1),
          refers?(Map.get(c, :type_ref), name),
          do: "#{n.name} (#{label} column #{i})"

    # references that only the original file holds (a business knowledge model's parameters, expressions that
    # are kept read-only) count too: deleting the type would leave them undefined
    shown = MapSet.new(nodes)

    retained =
      for {node, ref} <- DmnSpike.Dmn.Overlay.retained_type_refs(m),
          refers?(ref, name),
          not MapSet.member?(shown, node),
          uniq: true,
          do: "#{node} (kept from the file)"

    %{
      nodes: Enum.sort(nodes ++ columns ++ retained),
      types: for(t <- m.types, label <- refs_in(t, t.name, name), do: label)
    }
  end

  defp refs_in(t, label, name) do
    own = if refers?(t.ref, name) and label != name, do: [label], else: []
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

    # a built-in name is no more usable than an empty or a taken one: references would resolve to the built-in
    if String.trim(new) == "" or new in @builtins or
         Enum.any?(others, &(&1.name == new or effective(&1) == new)) do
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
    n = %{n | type_ref: rename_ref(n.type_ref, old, new)}
    swap = fn col -> Map.put(col, :type_ref, rename_ref(Map.get(col, :type_ref), old, new)) end

    case n.expr do
      %{kind: :table, inputs: ins, outputs: outs} = e ->
        %{n | expr: %{e | inputs: Enum.map(ins, swap), outputs: Enum.map(outs, swap)}}

      _ ->
        n
    end
  end

  defp rename_in(types, old, new) do
    Enum.map(types, fn t ->
      %{t | ref: rename_ref(t.ref, old, new), components: rename_in(t.components, old, new)}
    end)
  end

  # `Foo!` and `list<Foo>` follow `Foo`; a reference that does not mention it is left as it is
  defp rename_ref(ref, old, new),
    do: if(refers?(ref, old), do: map_ref(ref, &if(&1 == old, do: new, else: &1)), else: ref)
end
