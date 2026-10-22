defmodule DmnSpike.Model do
  @moduledoc """
  A tiny DRD. Every node has an expression made of named `rows` and a `result`
  (a literal is just a node without rows). Edges are `{from, to, kind}`:
  `from` is a requirement of `to`.
  """

  defstruct nodes: %{}, edges: []

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
        {id, %{id: id, type: type, name: name, x: x, y: y, w: 150, h: 60, expr: expr}}
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

    %__MODULE__{nodes: nodes, edges: edges}
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
end
