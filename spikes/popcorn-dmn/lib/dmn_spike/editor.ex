defmodule DmnSpike.Editor do
  @moduledoc """
  Owns the model, history and selection. All logic is Elixir; the JS below only
  forwards DOM events (pointer capture and screen->SVG coordinates need the DOM)
  and applies small patches.
  """
  use GenServer

  alias DmnSpike.{Autocomplete, Eval, Model, Panel, Svg}
  alias Popcorn.JS

  @name :editor

  @patch_js """
  ({ops}) => {
    for (const [k, sel, a, b] of ops) {
      const el = document.querySelector(sel);
      if (!el) continue;
      if (k === 'html') el.innerHTML = a;
      else if (k === 'attr') el.setAttribute(a, b);
      else if (k === 'disabled') el.disabled = a;
      else if (k === 'value') { el.value = a; el.setSelectionRange(b, b); el.focus(); }
    }
  }
  """

  @events_js """
  (_, {send}) => {
    const $ = (s) => document.querySelector(s);
    const svg = $('#drd'), pt = svg.createSVGPoint();
    const at = (e) => { pt.x = e.clientX; pt.y = e.clientY; return pt.matrixTransform(svg.getScreenCTM().inverse()); };
    const ed = (m) => send('editor', m);
    let id = null;
    svg.addEventListener('pointerdown', (e) => {
      const g = e.target.closest('[data-id]');
      if (!g) return;
      id = g.dataset.id; svg.setPointerCapture(e.pointerId);
      const p = at(e); ed({t: 'down', id, x: p.x, y: p.y});
    });
    svg.addEventListener('pointermove', (e) => { if (id) { const p = at(e); ed({t: 'move', x: p.x, y: p.y}); } });
    svg.addEventListener('pointerup', () => { if (id) ed({t: 'up'}); id = null; });

    const panel = $('#panel');
    const cell = (e, t) => ({t, cell: e.target.dataset.cell, text: e.target.value, caret: e.target.selectionStart});
    panel.addEventListener('input', (e) => { if (e.target.dataset.cell) ed(cell(e, 'cell')); });
    panel.addEventListener('focusin', (e) => { if (e.target.dataset.cell) ed(cell(e, 'focus')); });
    panel.addEventListener('keyup', (e) => {
      if (e.target.dataset.cell && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) ed(cell(e, 'focus'));
    });
    panel.addEventListener('keydown', (e) => {
      if (!e.target.dataset.cell) return;
      if (e.key === 'Enter') e.preventDefault();
      if ((e.key === 'Tab' && !e.shiftKey) && panel.querySelector('.ac li')) { e.preventDefault(); ed({...cell(e, 'ac'), pick: 0}); }
      if (e.key === 'Escape') ed({...cell(e, 'focus'), text: e.target.value, caret: -1});
    });
    panel.addEventListener('mousedown', (e) => {
      const li = e.target.closest('[data-pick]');
      if (!li) return;
      e.preventDefault();
      const ta = $(`[data-cell="${li.dataset.cell}"]`);
      ed({t: 'ac', cell: li.dataset.cell, text: ta.value, caret: ta.selectionStart, pick: Number(li.dataset.pick)});
    });
    document.addEventListener('keydown', (e) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      const k = e.key.toLowerCase();
      if (k === 'z') { e.preventDefault(); ed({t: e.shiftKey ? 'redo' : 'undo'}); }
      if (k === 'y') { e.preventDefault(); ed({t: 'redo'}); }
    });
    $('#undo').onclick = () => ed({t: 'undo'});
    $('#redo').onclick = () => ed({t: 'redo'});
  }
  """

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: @name)

  @impl true
  def init(_) do
    model = Model.sample()
    {:ok, %{model: model, past: [], future: [], selected: "front", drag: nil, group: nil, ac: nil}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    :ok = JS.await_ready()
    JS.run!(@events_js)
    render_all(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:wasm, msg}, state), do: {:noreply, event(msg, state)}
  def handle_info(_other, state), do: {:noreply, state}

  # --- events -------------------------------------------------------------

  defp event(%{"t" => "down", "id" => id, "x" => x, "y" => y}, state) do
    n = state.model.nodes[id]
    state = %{state | drag: {id, x - n.x, y - n.y, false}}
    select(state, id)
  end

  defp event(%{"t" => "move", "x" => x, "y" => y}, %{drag: {id, dx, dy, started?}} = state) do
    state = if started?, do: state, else: push_history(state, nil)
    model = Model.move(state.model, id, x - dx, y - dy)
    n = model.nodes[id]

    ops =
      [["attr", ~s|[data-id="#{id}"]|, "transform", Svg.transform(n)]] ++
        for {e, i} <- Model.edges_of(model, id), do: ["html", "#edge-#{i}", Svg.edge(model, e)]

    patch(ops)
    %{state | model: model, drag: {id, dx, dy, true}}
  end

  defp event(%{"t" => "up"}, state), do: %{state | drag: nil}

  defp event(%{"t" => "focus"} = msg, state), do: show_ac(msg, state)

  defp event(%{"t" => "cell", "cell" => cell, "text" => text} = msg, state) do
    {id, idx} = parse_cell(cell)
    key = {:cell, id, idx}
    state = if state.group == key, do: state, else: push_history(state, key)
    state = %{state | model: Model.set_text(state.model, id, idx, text)}
    {us, results} = :timer.tc(fn -> Eval.run(state.model) end)

    result = Enum.at(results[id].cells, idx)

    ops =
      [["html", "#hl-#{id}-#{idx}", Panel.hl(text, result)]] ++
        value_ops(state.model, id, results) ++ node_value_ops(state.model, results) ++ status_ops(state, us)

    patch(ops)
    show_ac(msg, %{state | group: key})
  end

  defp event(%{"t" => "ac", "cell" => cell, "text" => text, "caret" => caret, "pick" => pick} = msg, state) do
    {id, idx} = parse_cell(cell)
    {start, names} = Autocomplete.suggest(state.model, id, idx, text, caret)

    if Enum.at(names, pick) do
      {new_text, new_caret} = Autocomplete.accept(text, caret, start, names, pick)
      patch([["value", ~s|[data-cell="#{cell}"]|, new_text, new_caret]])
      event(%{msg | "t" => "cell", "text" => new_text, "caret" => new_caret}, state)
    else
      state
    end
  end

  defp event(%{"t" => "undo"}, %{past: [prev | past]} = state) do
    render_all(%{state | model: prev, past: past, future: [state.model | state.future], group: nil}, true)
  end

  defp event(%{"t" => "redo"}, %{future: [next | future]} = state) do
    render_all(%{state | model: next, future: future, past: [state.model | state.past], group: nil}, true)
  end

  defp event(_other, state), do: state

  # --- helpers ------------------------------------------------------------

  defp parse_cell(cell) do
    [id, idx] = String.split(cell, ":")
    {id, String.to_integer(idx)}
  end

  defp push_history(state, group) do
    state = %{state | past: Enum.take([state.model | state.past], 100), future: [], group: group}
    patch(history_ops(state))
    state
  end

  defp select(%{selected: id} = state, id), do: state

  defp select(state, id) do
    results = Eval.run(state.model)

    patch([
      ["attr", ~s|[data-id="#{state.selected}"]|, "class", "node"],
      ["attr", ~s|[data-id="#{id}"]|, "class", "node sel"],
      ["html", "#panel", Panel.render(state.model, id, results)]
    ])

    %{state | selected: id}
  end

  defp show_ac(%{"cell" => cell, "text" => text, "caret" => caret}, state) do
    {id, idx} = parse_cell(cell)
    names = if caret < 0, do: [], else: elem(Autocomplete.suggest(state.model, id, idx, text, caret), 1)
    patch([["html", "#ac-#{id}-#{idx}", Autocomplete.list_html(cell, names)]])
    state
  end

  defp value_ops(model, id, results) do
    for {_, idx} <- Enum.with_index(Model.cells(model.nodes[id])) do
      ["html", "#val-#{id}-#{idx}", Panel.cell_view(Enum.at(results[id].cells, idx))]
    end
  end

  defp node_value_ops(model, results) do
    for {nid, _} <- model.nodes, do: ["html", "#nv-#{nid}", Svg.node_value_text(results[nid])]
  end

  defp history_ops(state) do
    [["disabled", "#undo", state.past == []], ["disabled", "#redo", state.future == []]]
  end

  defp status_ops(state, us) do
    n = state.model.nodes |> Map.values() |> Enum.map(&length(Model.cells(&1))) |> Enum.sum()
    [["html", "#status", "evaluated #{n} cells in #{Float.round(us / 1000, 1)} ms"]] ++ history_ops(state)
  end

  defp render_all(state, return_state? \\ false) do
    {us, results} = :timer.tc(fn -> Eval.run(state.model) end)

    patch(
      [
        ["html", "#scene", Svg.scene(state.model, results, state.selected)],
        ["html", "#panel", Panel.render(state.model, state.selected, results)]
      ] ++ status_ops(state, us)
    )

    if return_state?, do: state, else: :ok
  end

  defp patch(ops), do: JS.run!(@patch_js, %{ops: ops})
end
