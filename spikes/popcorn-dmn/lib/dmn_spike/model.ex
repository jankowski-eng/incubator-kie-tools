defmodule DmnSpike.Model do
  @moduledoc """
  A tiny DRD. Every node has an expression made of named `rows` and a `result`
  (a literal is just a node without rows). Edges are `{from, to, kind}`:
  `from` is a requirement of `to`.
  """

  @type_refs %{
    "loan" => "tVerdict",
    "risk" => "tCategory",
    "back" => "tRatio",
    "front" => "tRatio",
    "dti" => "number",
    "piti" => "number",
    "app" => "tApplicant",
    "prod" => "tRequested"
  }

  defstruct nodes: %{}, edges: [], links: [], types: [], next: 1, doc: nil

  def sample do
    nodes =
      [
        {"loan", :decision, "Loan Pre-Qualification", 330, 30, [],
         ~s|if Front End Ratio <= Lender Acceptable PITI() and Back End Ratio <= Lender Acceptable DTI() then "Qualified" else "Not qualified"|},
        {"back", :decision, "Back End Ratio", 170, 140,
         [
           {"housing", "Front End Ratio * Applicant Data.Income / 100"},
           {"debts", "Applicant Data.Debt"}
         ], "(housing + debts) / Applicant Data.Income * 100"},
        {"front", :decision, "Front End Ratio", 490, 140,
         [
           {"pmt",
            "Requested Product.Amount * (Requested Product.Rate / 100 / 12) / (1 - 1 / (1 + Requested Product.Rate / 100 / 12) ** Requested Product.Term)"},
           {"tax", "Applicant Data.Tax"},
           {"insurance", "Applicant Data.Insurance"},
           {"income", "Applicant Data.Income"}
         ], "(pmt + tax + insurance) / income * 100"},
        {"risk", :decision, "Risk Category", 650, 280, [], ""},
        {"dti", :bkm, "Lender Acceptable DTI", 10, 30, [], "36"},
        {"piti", :bkm, "Lender Acceptable PITI", 650, 30, [], "28"},
        {"app", :input, "Applicant Data", 170, 280, [], "{Income: 9000, Tax: 400, Insurance: 120, Debt: 800}"},
        {"prod", :input, "Requested Product", 490, 280, [], "{Amount: 300000, Rate: 4.5, Term: 360}"}
      ]
      |> Map.new(fn {id, type, name, x, y, rows, result} ->
        expr = %{rows: Enum.map(rows, fn {n, t} -> %{name: n, text: t} end), result: result}
        expr = if type == :bkm, do: Map.put(expr, :params, []), else: expr

        node = %{
          id: id,
          type: type,
          name: name,
          description: "",
          x: x,
          y: y,
          w: 150,
          h: 60,
          expr: expr,
          type_ref: @type_refs[id]
        }

        {id, node}
      end)

    edges = [
      {"back", "loan", :info},
      {"front", "loan", :info},
      {"front", "back", :info},
      {"app", "back", :info},
      {"app", "front", :info},
      {"prod", "front", :info},
      {"front", "risk", :info},
      {"back", "risk", :info},
      {"dti", "loan", :knowledge},
      {"piti", "loan", :knowledge}
    ]

    nodes = put_in(nodes["risk"].expr, risk_table())
    %__MODULE__{nodes: nodes, edges: edges, types: DmnSpike.Types.sample()}
  end

  defp risk_table do
    %{
      kind: :table,
      hit_policy: "FIRST",
      inputs: [%{expr: "Front End Ratio"}, %{expr: "Back End Ratio"}],
      outputs: [%{name: ""}],
      note_title: nil,
      rules: [
        %{entries: ["< 20", "< 30"], outs: [~s|"Low"|], note: ""},
        %{entries: ["< 28", "-"], outs: [~s|"Medium"|], note: ""},
        %{entries: ["-", "-"], outs: [~s|"High"|], note: ""}
      ]
    }
  end

  @doc "Resizes an annotation or group so that its bottom-right corner is at `{x, y}` (minimum 60 × 30)."
  def resize(%__MODULE__{} = m, id, x, y),
    do: update_in(m.nodes[id], &%{&1 | w: max(round(x - &1.x), 60), h: max(round(y - &1.y), 30)})

  @doc "The elements that lie completely inside group `id`."
  def members(%__MODULE__{} = m, id) do
    g = m.nodes[id]

    for {k, n} <- m.nodes, k != id, n.x >= g.x, n.y >= g.y, n.x + n.w <= g.x + g.w, n.y + n.h <= g.y + g.h, do: k
  end

  @doc "Moves a node to `{x, y}`; a group takes the elements inside it along."
  def move(%__MODULE__{} = m, id, x, y) do
    n = m.nodes[id]
    {dx, dy} = {round(x) - n.x, round(y) - n.y}
    ids = if n.type == :group, do: [id | members(m, id)], else: [id]
    Enum.reduce(ids, m, fn k, acc -> update_in(acc.nodes[k], &%{&1 | x: &1.x + dx, y: &1.y + dy}) end)
  end

  @hit_policies ["UNIQUE", "FIRST", "ANY", "COLLECT", "RULE ORDER"]
  def hit_policies, do: @hit_policies

  def kind(%{expr: expr}), do: Map.get(expr, :kind, :context)

  # elements of the diagram that are not part of the decision graph: no expression, no value
  @artifacts [:annotation, :source, :group]
  def artifact?(%{type: t}), do: t in @artifacts
  def artifact_expr, do: %{kind: :raw, tag: nil}

  @doc "Requirements (evaluated) and links (association, authority requirement), as one list: the diagram's edges."
  def edges_all(%__MODULE__{edges: e, links: l}), do: e ++ l

  def new_table,
    do: %{
      kind: :table,
      hit_policy: "UNIQUE",
      inputs: [%{expr: ""}],
      outputs: [%{name: ""}],
      note_title: nil,
      rules: [%{entries: ["-"], outs: [""], note: ""}]
    }

  # only a decision can be a decision table; for an input or a business knowledge model this is a no-op
  def set_expr_kind(%__MODULE__{} = m, id, :table) do
    if m.nodes[id].type == :decision, do: put_in(m.nodes[id].expr, new_table()), else: m
  end

  def set_expr_kind(%__MODULE__{} = m, id, :context),
    do: put_in(m.nodes[id].expr, with_params(m.nodes[id], %{rows: [], result: ""}, params(m.nodes[id])))

  defp with_params(%{type: :bkm}, expr, params), do: Map.put(expr, :params, params)
  defp with_params(_node, expr, _params), do: expr

  @doc "Formal parameters of a business knowledge model (its function arguments)."
  def params(%{expr: expr}), do: Map.get(expr, :params, [])

  def set_params(%__MODULE__{} = m, id, text) do
    names = text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    put_in(m.nodes[id].expr, Map.put(m.nodes[id].expr, :params, names))
  end

  def cell_count(%{expr: %{kind: :table, inputs: ins, outputs: outs, rules: rules}}),
    do: length(ins) + length(rules) * (length(ins) + length(outs))

  def cell_count(%{expr: %{kind: :raw}}), do: 0
  def cell_count(node), do: length(cells(node))

  @doc "Cells of a context/literal node: `{label, text}`; the last has label `:result`. Tables and kept (read-only) expressions have none."
  def cells(%{expr: %{kind: kind}}) when kind in [:table, :raw], do: []

  def cells(%{expr: %{rows: rows, result: result}}),
    do: Enum.map(rows, &{&1.name, &1.text}) ++ [{:result, result}]

  def set_text(%__MODULE__{} = m, id, idx, text) do
    update_in(m.nodes[id].expr, fn %{rows: rows} = expr ->
      if idx < length(rows),
        do: %{expr | rows: List.update_at(rows, idx, &%{&1 | text: text})},
        else: %{expr | result: text}
    end)
  end

  # --- decision tables (paths: ["h", input], ["e", rule, input], ["o", rule, output], ["n", output]) ---

  def set_table_text(%__MODULE__{} = m, id, path, text) do
    update_in(m.nodes[id].expr, fn t ->
      case path do
        ["h", i] ->
          %{t | inputs: List.update_at(t.inputs, i, &%{&1 | expr: text})}

        ["e", r, i] ->
          %{
            t
            | rules:
                List.update_at(t.rules, r, fn rule -> %{rule | entries: List.replace_at(rule.entries, i, text)} end)
          }

        ["o", r, k] ->
          %{t | rules: List.update_at(t.rules, r, fn rule -> %{rule | outs: List.replace_at(rule.outs, k, text)} end)}

        ["n", k] ->
          %{t | outputs: List.update_at(t.outputs, k, &%{&1 | name: text})}
      end
    end)
  end

  def set_note(%__MODULE__{} = m, id, r, text),
    do: update_in(m.nodes[id].expr, fn t -> %{t | rules: List.update_at(t.rules, r, &Map.put(&1, :note, text))} end)

  def set_hit_policy(%__MODULE__{} = m, id, hp) when hp in @hit_policies, do: put_in(m.nodes[id].expr.hit_policy, hp)

  def add_rule(%__MODULE__{} = m, id) do
    update_in(m.nodes[id].expr, fn t ->
      %{
        t
        | rules:
            t.rules ++
              [%{entries: Enum.map(t.inputs, fn _ -> "-" end), outs: Enum.map(t.outputs, fn _ -> "" end), note: ""}]
      }
    end)
  end

  def del_rule(%__MODULE__{} = m, id, r),
    do: update_in(m.nodes[id].expr, fn t -> %{t | rules: List.delete_at(t.rules, r)} end)

  def add_output(%__MODULE__{} = m, id) do
    update_in(m.nodes[id].expr, fn t ->
      %{
        t
        | outputs: t.outputs ++ [%{name: "output #{length(t.outputs) + 1}"}],
          rules: Enum.map(t.rules, &%{&1 | outs: &1.outs ++ [""]})
      }
    end)
  end

  def del_output(%__MODULE__{} = m, id, k) do
    update_in(m.nodes[id].expr, fn t ->
      if length(t.outputs) <= 1,
        do: t,
        else: %{
          t
          | outputs: List.delete_at(t.outputs, k),
            rules: Enum.map(t.rules, &%{&1 | outs: List.delete_at(&1.outs, k)})
        }
    end)
  end

  def add_input(%__MODULE__{} = m, id) do
    update_in(m.nodes[id].expr, fn t ->
      %{t | inputs: t.inputs ++ [%{expr: ""}], rules: Enum.map(t.rules, &%{&1 | entries: &1.entries ++ ["-"]})}
    end)
  end

  def del_input(%__MODULE__{} = m, id, i) do
    update_in(m.nodes[id].expr, fn t ->
      %{
        t
        | inputs: List.delete_at(t.inputs, i),
          rules: Enum.map(t.rules, &%{&1 | entries: List.delete_at(&1.entries, i)})
      }
    end)
  end

  def edges_of(%__MODULE__{} = m, id) do
    m |> edges_all() |> Enum.with_index() |> Enum.filter(fn {{a, b, _}, _} -> a == id or b == id end)
  end

  @doc "Names usable in an expression of node `id`: requirement names and the rows before `idx`."
  def scope_names(%__MODULE__{} = m, id, idx) do
    reqs = for {from, ^id, _} <- m.edges, do: m.nodes[from].name
    rows = m.nodes[id].expr.rows |> Enum.take(idx) |> Enum.map(& &1.name)
    rows ++ reqs
  end

  # --- structure edits ------------------------------------------------------

  @kinds %{
    "decision" => {:decision, "decision"},
    "input" => {:input, "input data"},
    "bkm" => {:bkm, "business knowledge"},
    "annotation" => {:annotation, "annotation"},
    "source" => {:source, "knowledge source"},
    "group" => {:group, "group"}
  }
  @sizes %{annotation: {200, 60}, group: {320, 200}}

  @doc "Adds a node of `kind` centred on `{x, y}`; returns `{model, id}`."
  def add_node(%__MODULE__{} = m, kind, x, y) do
    {type, label} = Map.fetch!(@kinds, kind)
    # `next` is only a hint: an imported file may already use n<next>, n<next+1>, ...
    n = m.next |> Stream.iterate(&(&1 + 1)) |> Enum.find(&id_free?(m, "n#{&1}"))
    id = "n#{n}"
    names = MapSet.new(Map.values(m.nodes), & &1.name)
    base = "New #{label}"

    name =
      [base]
      |> Stream.concat(Stream.map(Stream.iterate(2, &(&1 + 1)), &"#{base} #{&1}"))
      |> Enum.find(&(not MapSet.member?(names, &1)))

    {w, h} = Map.get(@sizes, type, {150, 60})

    node = %{
      id: id,
      type: type,
      name: name,
      x: round(x - w / 2),
      y: round(y - h / 2),
      w: w,
      h: h,
      expr: if(type in @artifacts, do: artifact_expr(), else: %{rows: [], result: ""}),
      type_ref: nil,
      description: ""
    }

    {%{m | nodes: Map.put(m.nodes, id, node), next: n + 1}, id}
  end

  @doc "Kinds that can be created as a requirement of a node of `type` (empty when it can require nothing)."
  def required_kinds(type),
    do: for(kind <- ["input", "decision", "bkm"], valid_pair?(elem(@kinds[kind], 0), type), do: kind)

  @doc "What the create pad offers for a node of `type`: what it requires, and an annotation."
  def pad_kinds(type) when type in [:annotation, :group], do: []
  def pad_kinds(:input), do: ["annotation"]
  def pad_kinds(:source), do: ["input", "decision", "source", "annotation"]
  def pad_kinds(type), do: required_kinds(type) ++ ["source", "annotation"]

  @doc """
  Adds a node of `kind` that `to` requires and connects it. Decisions and inputs go below `to`,
  business knowledge beside it; the first spot that overlaps no node is used.
  """
  def add_required(%__MODULE__{} = m, to, kind) do
    target = m.nodes[to]

    if target && kind in pad_kinds(target.type) do
      {m, id} = add_node(m, kind, 0, 0)
      {x, y} = free_spot(m, id, target, kind)
      m = put_in(m.nodes[id], %{m.nodes[id] | x: x, y: y})
      {:ok, m} = connect(m, id, to)
      {:ok, m, id}
    else
      {:error, "#{kind} cannot be required by that node"}
    end
  end

  defp free_spot(m, id, target, kind) do
    others = for {k, n} <- m.nodes, k != id, do: n
    me = m.nodes[id]
    # business knowledge and annotations go beside the node, everything else below it
    {ks, dy} =
      if kind in ["bkm", "annotation", "source"] and target.type != :source,
        do: {[1, -1, 2, -2, 3, -3], 0},
        else: {[0, 1, -1, 2, -2, 3, -3], target.h + 80}

    ks
    |> Enum.map(&{target.x + &1 * (me.w + 40), target.y + dy})
    |> Enum.find(fn {x, y} -> not Enum.any?(others, &overlaps?(&1, x, y, me.w, me.h)) end)
    |> Kernel.||({target.x, target.y + dy + 100})
  end

  defp overlaps?(n, x, y, w, h), do: x < n.x + n.w + 20 and n.x < x + w + 20 and y < n.y + n.h + 20 and n.y < y + h + 20

  # An XML id must be unique in the whole document, not just among the nodes: an imported file may use
  # n1 for a variable or an expression. The ids this node will write (its own, its variable, its diagram
  # shape) are checked against everything the file already has.
  defp id_free?(m, id) do
    taken = if m.doc, do: m.doc.ids, else: MapSet.new()

    Enum.all?([id, id <> "-var", "dmnshape-drg-" <> id], fn candidate ->
      not Map.has_key?(m.nodes, candidate) and not MapSet.member?(taken, candidate)
    end)
  end

  def delete_node(%__MODULE__{} = m, id) do
    touches = fn {a, b, _} -> a == id or b == id end

    %{
      m
      | nodes: Map.delete(m.nodes, id),
        edges: Enum.reject(m.edges, touches),
        links: Enum.reject(m.links, touches)
    }
  end

  # `i` indexes edges_all/1: requirements first, then links
  def delete_edge(%__MODULE__{edges: edges} = m, i) when i < length(edges), do: %{m | edges: List.delete_at(edges, i)}

  def delete_edge(%__MODULE__{edges: edges, links: links} = m, i),
    do: %{m | links: List.delete_at(links, i - length(edges))}

  def rename(%__MODULE__{} = m, id, name), do: put_in(m.nodes[id].name, name)
  def set_type_ref(%__MODULE__{} = m, id, ref), do: put_in(m.nodes[id].type_ref, ref)
  def description(n), do: Map.get(n, :description) || ""
  def set_description(%__MODULE__{} = m, id, text), do: put_in(m.nodes[id].description, text)

  # `{id, name, kind}` of what points at `id`, and of what `id` points at, along `edges`
  defp incoming(m, id, edges), do: for({f, ^id, k} <- edges, n = m.nodes[f], do: {n.id, n.name, k})
  defp outgoing(m, id, edges), do: for({^id, t, k} <- edges, n = m.nodes[t], do: {n.id, n.name, k})

  @doc "The nodes `id` requires and the nodes that require `id`, as `{id, name, kind}` lists."
  def neighbours(%__MODULE__{} = m, id), do: {incoming(m, id, m.edges), outgoing(m, id, m.edges)}

  @doc "What `id` takes its authority from, and what takes its authority from `id`, as `{id, name, :authority}`."
  def authorities(%__MODULE__{} = m, id) do
    authority = Enum.filter(m.links, &(elem(&1, 2) == :authority))
    {incoming(m, id, authority), outgoing(m, id, authority)}
  end

  @doc "Everything joined to `id` by a link (association, authority requirement), as `{id, name, kind}`."
  def links_of(%__MODULE__{} = m, id), do: incoming(m, id, m.links) ++ outgoing(m, id, m.links)

  @doc "DMN requirement rules: input/decision -> decision (information), bkm -> decision/bkm (knowledge)."
  def connect(%__MODULE__{} = m, from, to) do
    a = m.nodes[from]
    b = m.nodes[to]

    cond do
      is_nil(a) or is_nil(b) ->
        {:error, "nothing to connect"}

      from == to ->
        {:error, "a node cannot require itself"}

      Enum.any?(edges_all(m), fn {x, y, _} ->
        (x == from and y == to) or (x == to and y == from and annotated?(a, b))
      end) ->
        {:error, "already connected"}

      annotated?(a, b) ->
        {:ok, add_link(m, a, b)}

      authority_pair?(a.type, b.type) ->
        if {to, from, :authority} in m.links,
          do: {:error, "that would create a cycle"},
          else: {:ok, %{m | links: m.links ++ [{from, to, :authority}]}}

      not valid_pair?(a.type, b.type) ->
        {:error, "#{a.type} cannot be required by #{b.type}"}

      requires?(m, from, to) ->
        {:error, "that would create a cycle"}

      true ->
        {:ok, %{m | edges: m.edges ++ [{from, to, if(a.type == :bkm, do: :knowledge, else: :info)}]}}
    end
  end

  # an association joins an annotation to anything else, always stored annotation first
  defp annotated?(a, b), do: (a.type == :annotation or b.type == :annotation) and not (a.type == b.type)
  defp add_link(m, %{type: :annotation} = a, b), do: %{m | links: m.links ++ [{a.id, b.id, :association}]}
  defp add_link(m, a, %{type: :annotation} = b), do: %{m | links: m.links ++ [{b.id, a.id, :association}]}

  # authority requirements: a knowledge source requires an input, decision or source as its authority,
  # and a decision, business knowledge model or source can require a source
  defp authority_pair?(from, :source) when from in [:input, :decision, :source], do: true
  defp authority_pair?(:source, to) when to in [:decision, :bkm], do: true
  defp authority_pair?(_, _), do: false

  defp valid_pair?(:input, :decision), do: true
  defp valid_pair?(:decision, :decision), do: true
  defp valid_pair?(:bkm, t) when t in [:decision, :bkm], do: true
  defp valid_pair?(_, _), do: false

  # does `a` (transitively) require `b`?
  defp requires?(m, a, b, seen \\ MapSet.new()) do
    reqs = for {x, ^a, _} <- m.edges, do: x

    Enum.any?(reqs, fn r ->
      r == b or (not MapSet.member?(seen, r) and requires?(m, r, b, MapSet.put(seen, a)))
    end)
  end
end
