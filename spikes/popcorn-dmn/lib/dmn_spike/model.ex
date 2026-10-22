defmodule DmnSpike.Model do
  @moduledoc """
  A tiny DRD. Every node has an expression made of named `rows` and a `result`
  (a literal is just a node without rows). Edges are `{from, to, kind}`:
  `from` is a requirement of `to`.
  """

  @type_refs %{
    "loan" => "tVerdict",
    "back" => "tRatio",
    "front" => "tRatio",
    "dti" => "number",
    "piti" => "number",
    "app" => "tApplicant",
    "prod" => "tRequested"
  }

  defstruct nodes: %{}, edges: [], types: [], next: 1

  def sample do
    nodes =
      [
        {"loan", :decision, "Loan Pre-Qualification", 330, 30, [],
         ~s|if Front End Ratio <= Lender Acceptable PITI and Back End Ratio <= Lender Acceptable DTI then "Qualified" else "Not qualified"|},
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
        {"dti", :bkm, "Lender Acceptable DTI", 10, 30, [], "36"},
        {"piti", :bkm, "Lender Acceptable PITI", 650, 30, [], "28"},
        {"app", :input, "Applicant Data", 170, 280, [],
         "{Income: 9000, Tax: 400, Insurance: 120, Debt: 800}"},
        {"prod", :input, "Requested Product", 490, 280, [],
         "{Amount: 300000, Rate: 4.5, Term: 360}"}
      ]
      |> Map.new(fn {id, type, name, x, y, rows, result} ->
        expr = %{rows: Enum.map(rows, fn {n, t} -> %{name: n, text: t} end), result: result}
        node = %{id: id, type: type, name: name, x: x, y: y, w: 150, h: 60, expr: expr, type_ref: @type_refs[id]}
        {id, node}
      end)

    edges = [
      {"back", "loan", :info},
      {"front", "loan", :info},
      {"front", "back", :info},
      {"app", "back", :info},
      {"app", "front", :info},
      {"prod", "front", :info},
      {"dti", "loan", :knowledge},
      {"piti", "loan", :knowledge}
    ]

    %__MODULE__{nodes: nodes, edges: edges, types: DmnSpike.Types.sample()}
  end

  def move(%__MODULE__{} = m, id, x, y), do: update_in(m.nodes[id], &%{&1 | x: round(x), y: round(y)})

  @doc "Cells of a node: `{label, text}`; the last has label `:result`."
  def cells(%{expr: %{rows: rows, result: result}}),
    do: Enum.map(rows, &{&1.name, &1.text}) ++ [{:result, result}]

  def set_text(%__MODULE__{} = m, id, idx, text) do
    update_in(m.nodes[id].expr, fn %{rows: rows} = expr ->
      if idx < length(rows),
        do: %{expr | rows: List.update_at(rows, idx, &%{&1 | text: text})},
        else: %{expr | result: text}
    end)
  end

  def edges_of(%__MODULE__{edges: edges}, id) do
    edges |> Enum.with_index() |> Enum.filter(fn {{a, b, _}, _} -> a == id or b == id end)
  end

  @doc "Names usable in an expression of node `id`: requirement names and the rows before `idx`."
  def scope_names(%__MODULE__{} = m, id, idx) do
    reqs = for {from, ^id, _} <- m.edges, do: m.nodes[from].name
    rows = m.nodes[id].expr.rows |> Enum.take(idx) |> Enum.map(& &1.name)
    rows ++ reqs
  end

  # --- structure edits ------------------------------------------------------

  @kinds %{"decision" => {:decision, "decision"}, "input" => {:input, "input data"}, "bkm" => {:bkm, "business knowledge"}}

  @doc "Adds a node of `kind` centred on `{x, y}`; returns `{model, id}`."
  def add_node(%__MODULE__{} = m, kind, x, y) do
    {type, label} = Map.fetch!(@kinds, kind)
    id = "n#{m.next}"
    names = MapSet.new(Map.values(m.nodes), & &1.name)
    base = "New #{label}"
    name = Enum.find([base | Enum.map(2..99, &"#{base} #{&1}")], &(not MapSet.member?(names, &1)))

    node = %{
      id: id, type: type, name: name, x: round(x - 75), y: round(y - 30), w: 150, h: 60,
      expr: %{rows: [], result: ""}, type_ref: nil
    }

    {%{m | nodes: Map.put(m.nodes, id, node), next: m.next + 1}, id}
  end

  def delete_node(%__MODULE__{} = m, id) do
    %{m | nodes: Map.delete(m.nodes, id), edges: Enum.reject(m.edges, fn {a, b, _} -> a == id or b == id end)}
  end

  def delete_edge(%__MODULE__{} = m, i), do: %{m | edges: List.delete_at(m.edges, i)}

  def rename(%__MODULE__{} = m, id, name), do: put_in(m.nodes[id].name, name)
  def set_type_ref(%__MODULE__{} = m, id, ref), do: put_in(m.nodes[id].type_ref, ref)

  @doc "DMN requirement rules: input/decision -> decision (information), bkm -> decision/bkm (knowledge)."
  def connect(%__MODULE__{} = m, from, to) do
    a = m.nodes[from]
    b = m.nodes[to]

    cond do
      is_nil(a) or is_nil(b) -> {:error, "nothing to connect"}
      from == to -> {:error, "a node cannot require itself"}
      Enum.any?(m.edges, fn {x, y, _} -> x == from and y == to end) -> {:error, "already connected"}
      not valid_pair?(a.type, b.type) -> {:error, "#{a.type} cannot be required by #{b.type}"}
      requires?(m, from, to) -> {:error, "that would create a cycle"}
      true -> {:ok, %{m | edges: m.edges ++ [{from, to, if(a.type == :bkm, do: :knowledge, else: :info)}]}}
    end
  end

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
