defmodule DmnSpike.Editor do
  @moduledoc """
  Owns the model, history and selection. All logic is Elixir; the JS below only
  forwards DOM events (pointer capture, drag & drop and screen->SVG coordinates
  need the DOM) and applies small `[kind, selector, ...]` patches.
  """
  use GenServer

  alias DmnSpike.{Autocomplete, Dmn, Eval, Fmt, Layout, Model, Panel, Svg, Types, TypesPanel, View}
  alias Popcorn.JS

  @name :editor

  @patch_js """
  ({ops}) => {
    for (const [k, sel, a, b] of ops) {
      const el = document.querySelector(sel);
      if (!el) continue;
      if (k === 'html') el.innerHTML = a;
      else if (k === 'outer') el.outerHTML = a;
      else if (k === 'attr') el.setAttribute(a, b);
      else if (k === 'disabled') el.disabled = a;
      else if (k === 'hidden') el.hidden = a;
      else if (k === 'focus') { el.focus(); el.select?.(); }
      else if (k === 'value') { el.value = a; el.setSelectionRange(b, b); el.focus(); }
    }
  }
  """

  @download_js """
  ({xml, name}) => {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([xml], {type: 'application/xml'}));
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }
  """

  @events_js """
  (_, {send}) => {
    // the editor process can restart; the listeners from the first start keep working, so never add a second set
    if (window.__dmnEditorBound) return;
    window.__dmnEditorBound = true;
    const $ = (s) => document.querySelector(s);
    const ed = (m) => send('editor', m);
    const svg = $('#drd'), pt = svg.createSVGPoint();
    const at = (e) => { pt.x = e.clientX; pt.y = e.clientY; return pt.matrixTransform(svg.getScreenCTM().inverse()); };

    // diagram: drag nodes, connect from a node's handle, select edges, pan on the background, wheel to zoom
    let mode = null, last = null;
    const scale = () => svg.getScreenCTM().a; // screen px per SVG unit
    svg.addEventListener('wheel', (e) => { e.preventDefault(); const p = at(e); ed({t: 'zoom', f: Math.exp(e.deltaY * 0.0015), x: p.x, y: p.y}); }, {passive: false});
    svg.addEventListener('pointerdown', (e) => {
      const h = e.target.closest('[data-handle]'), g = e.target.closest('[data-id]'), l = e.target.closest('[data-edge]');
      const mk = e.target.closest('[data-create]');
      if (e.target.closest('[data-info]')) ed({t: 'click', what: 'dock:props'});
      if (mk) ed({t: 'create', kind: mk.dataset.create});
      else if (e.target.closest('[data-typepill]')) ed({t: 'focus_type'});
      else if (e.target.closest('[data-del]')) ed({t: 'delete'});
      else if (e.target.closest('[data-resize]')) { mode = 'resize'; svg.setPointerCapture(e.pointerId); ed({t: 'rstart', id: e.target.closest('[data-resize]').dataset.resize}); }
      else if (h) { mode = 'connect'; svg.setPointerCapture(e.pointerId); ed({t: 'cstart', id: h.dataset.handle}); }
      else if (g) { mode = 'drag'; svg.setPointerCapture(e.pointerId); const p = at(e); ed({t: 'down', id: g.dataset.id, x: p.x, y: p.y}); }
      else if (l) ed({t: 'edge', i: Number(l.dataset.edge)});
      else { mode = 'pan'; last = {x: e.clientX, y: e.clientY}; svg.setPointerCapture(e.pointerId); }
    });
    // sent as an event so it is handled after the selection has re-rendered the panel
    const rename = () => ed({t: 'rename'});
    // pointer capture retargets the click events to the svg, so look under the pointer
    svg.addEventListener('dblclick', (e) => { if (document.elementFromPoint(e.clientX, e.clientY)?.closest('[data-id]')) rename(); });
    svg.addEventListener('pointermove', (e) => {
      if (!mode) return;
      if (mode === 'pan') {
        const s = scale();
        ed({t: 'pan', dx: -(e.clientX - last.x) / s, dy: -(e.clientY - last.y) / s});
        last = {x: e.clientX, y: e.clientY};
        return;
      }
      const p = at(e);
      ed({t: mode === 'drag' ? 'move' : mode === 'resize' ? 'rmove' : 'cmove', x: p.x, y: p.y});
    });
    svg.addEventListener('pointerup', (e) => {
      if (mode === 'drag' || mode === 'resize') ed({t: 'up'});
      if (mode === 'connect') {
        const hit = document.elementFromPoint(e.clientX, e.clientY)?.closest('[data-id]');
        ed({t: 'cend', to: hit ? hit.dataset.id : null});
      }
      mode = null;
    });

    // palette: drag new elements onto the canvas
    $('#palette').addEventListener('dragstart', (e) => e.dataTransfer.setData('text/plain', e.target.closest('[data-kind]').dataset.kind));
    svg.addEventListener('dragover', (e) => e.preventDefault());
    svg.addEventListener('drop', (e) => {
      e.preventDefault();
      const kind = e.dataTransfer.getData('text/plain'), p = at(e);
      if (kind) ed({t: 'add', kind, x: p.x, y: p.y});
    });

    // DMN file import
    // Popcorn 0.4.0-next.9 traps ("memory access out of bounds") when one JS->BEAM message is
    // larger than 64 KiB, so a file is sent in small chunks and reassembled in Elixir.
    $('#file').addEventListener('change', async (e) => {
      const f = e.target.files[0];
      if (!f) return;
      const text = await f.text(), parts = [], size = 16 * 1024;
      for (let i = 0; i < text.length;) {
        let end = Math.min(i + size, text.length);
        const c = text.charCodeAt(end - 1);
        if (end < text.length && c >= 0xd800 && c <= 0xdbff) end--; // never split a surrogate pair
        parts.push(text.slice(i, end));
        i = end;
      }
      if (parts.length === 0) parts.push('');
      parts.forEach((part, i) => ed({t: 'import_chunk', name: f.name, i, n: parts.length, text: part}));
      e.target.value = '';
    });

    // expression cells (highlighted textareas with autocomplete)
    const panel = $('#panel');
    const cell = (e, t) => ({t, cell: e.target.dataset.cell, text: e.target.value, caret: e.target.selectionStart});
    panel.addEventListener('input', (e) => { if (e.target.dataset.cell) ed(cell(e, 'cell')); });
    panel.addEventListener('focusin', (e) => { if (e.target.dataset.cell) ed(cell(e, 'focus')); });
    panel.addEventListener('keyup', (e) => {
      if (e.target.dataset.cell && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) ed(cell(e, 'focus'));
    });
    panel.addEventListener('keydown', (e) => {
      if (e.target.dataset.op === 'dtcell' && e.key === 'Enter') {
        // spreadsheet flow: Enter goes down a row, Shift+Enter up
        e.preventDefault();
        const td = e.target.closest('td'), tr = td.parentElement;
        const next = e.shiftKey ? tr.previousElementSibling : tr.nextElementSibling;
        next?.children[td.cellIndex]?.querySelector('textarea, input')?.focus();
      }
      if (!e.target.dataset.cell) return;
      if (e.key === 'Enter') e.preventDefault();
      if (e.key === 'Tab' && !e.shiftKey && panel.querySelector('.ac li')) { e.preventDefault(); ed({...cell(e, 'ac'), pick: 0}); }
      if (e.key === 'Escape') ed({...cell(e, 'focus'), caret: -1});
    });
    panel.addEventListener('mousedown', (e) => {
      const li = e.target.closest('[data-pick]');
      if (!li) return;
      e.preventDefault();
      const ta = $(`[data-cell="${li.dataset.cell}"]`);
      ed({t: 'ac', cell: li.dataset.cell, text: ta.value, caret: ta.selectionStart, pick: Number(li.dataset.pick)});
    });

    // generic controls: data-op (inputs/selects/checkboxes) and data-click (buttons)
    const op = (e, kind) => {
      const d = e.target.dataset;
      if (!d.op) return;
      ed({t: 'op', op: d.op, path: d.path ?? null, id: d.id ?? null, kind, value: e.target.type === 'checkbox' ? e.target.checked : e.target.value});
    };
    const textual = (el) => el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'checkbox');
    document.addEventListener('input', (e) => { if (textual(e.target)) op(e, 'input'); });
    document.addEventListener('change', (e) => op(e, 'change'));
    document.addEventListener('click', (e) => {
      const b = e.target.closest('[data-click]');
      if (b) ed({t: 'click', what: b.dataset.click});
    });
    document.addEventListener('keydown', (e) => {
      if (e.target.closest('input, textarea, select')) {
        if ((e.metaKey || e.ctrlKey) && ['z', 'y'].includes(e.key.toLowerCase())) e.preventDefault();
        else return;
      }
      const k = e.key.toLowerCase();
      if ((e.metaKey || e.ctrlKey) && k === 'z') { e.preventDefault(); ed({t: e.shiftKey ? 'redo' : 'undo'}); }
      else if ((e.metaKey || e.ctrlKey) && k === 'y') { e.preventDefault(); ed({t: 'redo'}); }
      else if (k === 'f2') { e.preventDefault(); rename(); }
      else if ((k === 'delete' || k === 'backspace') && (e.target === document.body || e.target.closest('#drd'))) {
        // only from the canvas: with focus on a toolbar button Backspace must not delete the selection
        e.preventDefault();
        ed({t: 'delete'});
      }
    });
  }
  """

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: @name)

  @impl true
  def init(_) do
    state = %{
      model: Model.sample(),
      past: [],
      future: [],
      selected: "front",
      sel_edge: nil,
      drag: nil,
      group: nil,
      connect: nil,
      resize: nil,
      type_sel: 0,
      dock: "expr",
      tab: "editor",
      report: nil,
      name: "Popcorn spike",
      upload: nil,
      view: nil
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    :ok = JS.await_ready()
    JS.run!(@events_js)
    render_all(state)
    {:noreply, state}
  end

  @impl true
  # an exception in one event must not restart the editor (that would silently reset the model)
  def handle_info({:wasm, msg}, state) do
    {:noreply, event(msg, state)}
  rescue
    e ->
      say(state, "internal error: " <> inspect(e, limit: 4, printable_limit: 300))
      {:noreply, state}
  catch
    kind, reason ->
      say(state, "internal error: " <> inspect({kind, reason}, limit: 4, printable_limit: 300))
      {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- diagram events -------------------------------------------------------------

  defp event(%{"t" => "down", "id" => id, "x" => x, "y" => y}, state) do
    n = state.model.nodes[id]
    select(%{state | drag: {id, x - n.x, y - n.y, false}}, {:node, id})
  end

  defp event(%{"t" => "edge", "i" => i}, state), do: select(state, {:edge, i})

  defp event(%{"t" => "move", "x" => x, "y" => y}, %{drag: {id, dx, dy, started?}} = state) do
    state = if started?, do: state, else: push_history(state, nil)
    # a group carries what is inside it
    ids = if state.model.nodes[id].type == :group, do: [id | Model.members(state.model, id)], else: [id]
    model = Model.move(state.model, id, x - dx, y - dy)

    moves = for k <- ids, do: ["attr", ~s|[data-id="#{k}"]|, "transform", Svg.transform(model.nodes[k])]
    patch(moves ++ (ids |> Enum.flat_map(&edge_ops(model, &1)) |> Enum.uniq()))
    %{state | model: model, drag: {id, dx, dy, true}}
  end

  defp event(%{"t" => "up"}, state) do
    patch([["attr", "#drd", "viewBox", viewbox(state)]])
    %{state | drag: nil, resize: nil}
  end

  # history is recorded on the first move, so a click on the handle is not an undo step
  defp event(%{"t" => "rstart", "id" => id}, state), do: %{state | resize: {id, false}}

  defp event(%{"t" => "rmove", "x" => x, "y" => y}, %{resize: {id, started?}} = state) do
    state = if started?, do: state, else: push_history(state, nil)
    model = Model.resize(state.model, id, x, y)
    # artifacts have no value, so nothing needs evaluating while the size changes
    patch(
      [["outer", ~s|[data-id="#{id}"]|, Svg.node_html(model.nodes[id], nil, state.selected)]] ++ edge_ops(model, id)
    )

    %{state | model: model, resize: {id, true}}
  end

  defp event(%{"t" => "pan", "dx" => dx, "dy" => dy}, state), do: set_view(state, View.pan(current_view(state), dx, dy))

  defp event(%{"t" => "zoom", "f" => f, "x" => x, "y" => y}, state),
    do: set_view(state, View.zoom(current_view(state), f, x, y))

  defp event(%{"t" => "click", "what" => w}, state) when w in ["zoom-in", "zoom-out"] do
    v = current_view(state)
    {cx, cy} = View.center(v)
    set_view(state, View.zoom(v, if(w == "zoom-in", do: 0.8, else: 1.25), cx, cy))
  end

  defp event(%{"t" => "click", "what" => "fit"}, state) do
    state = %{state | view: nil}
    patch([["attr", "#drd", "viewBox", viewbox(state)]])
    state
  end

  defp event(%{"t" => "cstart", "id" => id}, state), do: %{state | connect: id}

  defp event(%{"t" => "cmove", "x" => x, "y" => y}, %{connect: from} = state) when from != nil do
    patch([["html", "#preview", Svg.preview(state.model, from, {x, y})]])
    state
  end

  defp event(%{"t" => "cend", "to" => to}, %{connect: from} = state) when from != nil do
    patch([["html", "#preview", ""]])
    state = %{state | connect: nil}

    with true <- is_binary(to), {:ok, model} <- Model.connect(state.model, from, to) do
      state |> push_history(nil) |> Map.put(:model, model) |> render_all(true)
    else
      {:error, reason} -> say(state, "✗ #{reason}")
      _ -> state
    end
  end

  defp event(%{"t" => "add", "kind" => kind, "x" => x, "y" => y}, state) do
    state = push_history(state, nil)
    {model, id} = Model.add_node(state.model, kind, x, y)
    render_all(%{state | model: model, selected: id, sel_edge: nil}, true)
  end

  defp event(%{"t" => "create", "kind" => kind}, %{selected: id} = state) when id != nil do
    case Model.add_required(state.model, id, kind) do
      {:ok, model, new} ->
        state = push_history(state, nil)
        state = render_all(%{state | model: model, selected: new, sel_edge: nil}, true)
        patch([["focus", "#panel .nname"]])
        state

      {:error, msg} ->
        say(state, msg)
    end
  end

  defp event(%{"t" => "delete"}, %{sel_edge: i} = state) when i != nil do
    state
    |> push_history(nil)
    |> Map.update!(:model, &Model.delete_edge(&1, i))
    |> Map.put(:sel_edge, nil)
    |> render_all(true)
  end

  defp event(%{"t" => "delete"}, %{selected: id} = state) when id != nil do
    state
    |> push_history(nil)
    |> Map.update!(:model, &Model.delete_node(&1, id))
    |> Map.put(:selected, nil)
    |> render_all(true)
  end

  defp event(%{"t" => "click", "what" => "dock:" <> dock}, state) when dock in ["expr", "props"] do
    state = %{state | dock: dock}
    results = Eval.run(state.model)
    patch([["html", "#panel", Panel.render(state.model, state.selected, results, dock)]])
    state
  end

  defp event(%{"t" => "click", "what" => "goto:" <> id}, state) do
    if state.model.nodes[id], do: select(%{state | sel_edge: nil}, {:node, id}), else: state
  end

  defp event(%{"t" => "op", "op" => "ndesc", "id" => id, "value" => v}, state) do
    state = push_history(state, {:ndesc, id}, :merge)
    state = %{state | model: Model.set_description(state.model, id, v)}
    patch([["html", "#info-#{id}", Svg.info(state.model.nodes[id])]])
    state
  end

  defp event(%{"t" => "focus_type"}, state) do
    patch([["focus", "#panel select[data-op=ntype]"]])
    state
  end

  defp event(%{"t" => "rename"}, state) do
    patch([["focus", "#panel .nname"]])
    state
  end

  defp event(%{"t" => "click", "what" => "dismiss-report"}, state) do
    patch([["html", "#report", ""]])
    %{state | report: nil}
  end

  defp event(%{"t" => "click", "what" => "layout"}, state) do
    state = push_history(state, nil)
    render_all(%{state | model: Layout.run(state.model)}, true)
  end

  defp event(%{"t" => "import_chunk", "name" => file, "i" => i, "n" => n, "text" => part}, state) do
    {^file, ^n, parts} =
      case state.upload do
        {^file, ^n, _} = u -> u
        _ -> {file, n, %{}}
      end

    parts = Map.put(parts, i, part)

    if map_size(parts) == n do
      text = 0..(n - 1) |> Enum.map_join(&Map.fetch!(parts, &1))
      event(%{"t" => "import", "text" => text, "name" => file}, %{state | upload: nil})
    else
      %{state | upload: {file, n, parts}}
    end
  end

  defp event(%{"t" => "import", "text" => text, "name" => file}, state) do
    case Dmn.from_xml(text) do
      {:ok, model, report} ->
        state = push_history(state, nil)
        name = report.name || Path.rootname(file)
        selected = model.nodes |> Map.values() |> Enum.find(&(&1.type == :decision)) |> then(&(&1 && &1.id))

        render_all(
          %{state | model: model, selected: selected, sel_edge: nil, report: {:ok, file, report}, name: name},
          true
        )

      {:error, msg} ->
        render_all(%{state | report: {:error, file, msg}}, true)
    end
  end

  defp event(%{"t" => "click", "what" => "export"}, state) do
    file = (state.name |> String.replace(~r/[^\w\- ]+/u, "") |> String.trim() |> String.replace(" ", "-")) <> ".dmn"
    JS.run!(@download_js, %{xml: Dmn.to_xml(state.model, state.name), name: file})
    say(state, "exported #{file}")
  end

  defp event(%{"t" => "click", "what" => "tab:" <> tab}, state), do: render_all(%{state | tab: tab}, true)
  defp event(%{"t" => "click", "what" => w}, state) when w in ["undo", "redo"], do: event(%{"t" => w}, state)

  defp event(%{"t" => "click", "what" => "add-type"}, state) do
    names = MapSet.new(state.model.types, & &1.name)
    name = Stream.iterate(1, &(&1 + 1)) |> Stream.map(&"tNewType#{&1}") |> Enum.find(&(not MapSet.member?(names, &1)))
    edit_types(%{state | type_sel: length(state.model.types)}, fn types -> types ++ [Types.new_type(name)] end)
  end

  defp event(%{"t" => "click", "what" => "pick-type:" <> i}, state) do
    state = %{state | type_sel: String.to_integer(i)}
    patch_types(state)
    state
  end

  defp event(%{"t" => "click", "what" => "add-child:" <> p}, state),
    do: edit_types(state, &Types.add_child(&1, path(p), Types.new_type("field")))

  defp event(%{"t" => "click", "what" => "del-type:" <> p}, state),
    do: edit_types(state, &Types.delete(&1, path(p)))

  defp event(%{"t" => "undo"}, %{past: [prev | past]} = state),
    do: render_all(%{state | model: prev, past: past, future: [state.model | state.future], group: nil}, true)

  defp event(%{"t" => "redo"}, %{future: [next | future]} = state),
    do: render_all(%{state | model: next, future: future, past: [state.model | state.past], group: nil}, true)

  # --- expression cells -------------------------------------------------------------

  defp event(%{"t" => "focus"} = msg, state), do: show_ac(msg, state)

  defp event(%{"t" => "cell", "cell" => cell, "text" => text} = msg, state) do
    {id, idx} = parse_cell(cell)
    state = push_history(state, {:cell, id, idx}, :merge)
    state = %{state | model: Model.set_text(state.model, id, idx, text)}
    {us, results} = :timer.tc(fn -> Eval.run(state.model) end)
    result = Enum.at(results[id].cells, idx)

    patch([["html", "#hl-#{id}-#{idx}", Panel.hl(text, result)] | refresh_ops(state, results, us)])
    show_ac(msg, state)
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

  # --- node and data type controls -----------------------------------------------------

  # the browser fires `change` when a text field loses focus; the typing was already applied by `input`
  defp event(%{"t" => "op", "op" => op, "kind" => "change", "id" => id, "value" => v} = msg, state)
       when op in ["nname", "ndesc"] do
    node = state.model.nodes[id]
    current = if op == "nname", do: node && node.name, else: node && Model.description(node)
    if current == v, do: state, else: event(Map.put(msg, "kind", "commit"), state)
  end

  defp event(%{"t" => "op", "op" => "nname", "id" => id, "value" => v}, state) do
    state = push_history(state, {:nname, id}, :merge)
    state = %{state | model: Model.rename(state.model, id, v)}
    patch([["html", "#nm-#{id}", Fmt.esc(v)] | refresh_ops(state)])
    state
  end

  defp event(%{"t" => "op", "op" => "ntype", "id" => id, "value" => v}, state) do
    state = push_history(state, nil)
    state = %{state | model: Model.set_type_ref(state.model, id, if(v == "", do: nil, else: v))}
    patch([["html", "#pad-#{id}", Svg.pad(state.model.nodes[id])] | refresh_ops(state)])
    state
  end

  defp event(%{"t" => "op", "op" => "nparams", "id" => id, "value" => v}, state) do
    state = push_history(state, {:nparams, id}, :merge)
    state = %{state | model: Model.set_params(state.model, id, v)}
    patch(refresh_ops(state))
    state
  end

  defp event(%{"t" => "op", "op" => "nexpr", "id" => id, "value" => v}, state) do
    state = push_history(state, nil)
    kind = if v == "table", do: :table, else: :context
    render_all(%{state | model: Model.set_expr_kind(state.model, id, kind)}, true)
  end

  defp event(%{"t" => "op", "op" => "dtcell", "id" => id, "path" => p, "value" => v}, state) do
    state = push_history(state, {:dt, id, p}, :merge)
    state = %{state | model: Model.set_table_text(state.model, id, table_path(p), v)}
    patch(refresh_ops(state))
    state
  end

  defp event(%{"t" => "op", "op" => "dtnote", "id" => id, "path" => r, "value" => v}, state) do
    state = push_history(state, {:note, id, r}, :merge)
    %{state | model: Model.set_note(state.model, id, String.to_integer(r), v)}
  end

  defp event(%{"t" => "op", "op" => "dthp", "id" => id, "value" => v}, state) do
    state = push_history(state, nil)
    state = %{state | model: Model.set_hit_policy(state.model, id, v)}
    patch(refresh_ops(state))
    state
  end

  defp event(%{"t" => "click", "what" => "dt-add-rule:" <> id}, state), do: edit_table(state, &Model.add_rule(&1, id))
  defp event(%{"t" => "click", "what" => "dt-add-input:" <> id}, state), do: edit_table(state, &Model.add_input(&1, id))

  defp event(%{"t" => "click", "what" => "dt-add-output:" <> id}, state),
    do: edit_table(state, &Model.add_output(&1, id))

  defp event(%{"t" => "click", "what" => "dt-del-output:" <> rest}, state) do
    [id, k] = String.split(rest, ":")
    edit_table(state, &Model.del_output(&1, id, String.to_integer(k)))
  end

  defp event(%{"t" => "click", "what" => "dt-del-rule:" <> rest}, state) do
    [id, r] = String.split(rest, ":")
    edit_table(state, &Model.del_rule(&1, id, String.to_integer(r)))
  end

  defp event(%{"t" => "click", "what" => "dt-del-input:" <> rest}, state) do
    [id, i] = String.split(rest, ":")
    edit_table(state, &Model.del_input(&1, id, String.to_integer(i)))
  end

  defp event(%{"t" => "op", "op" => "tname", "path" => p, "value" => v, "kind" => kind}, state) do
    path = path(p)
    state = push_history(state, {:tname, p}, :merge)

    model =
      case path do
        [i] -> Types.rename_top(state.model, i, v)
        _ -> %{state.model | types: Types.update(state.model.types, path, &%{&1 | name: v})}
      end

    state = %{state | model: model}
    patch(refresh_ops(state))
    if match?([_], path), do: patch([["html", "#tn-#{p}", Fmt.esc(v)]])
    if kind == "change", do: patch_types(state)
    state
  end

  defp event(%{"t" => "op", "op" => "tref", "path" => p, "value" => v}, state),
    do: edit_types(state, &Types.update(&1, path(p), fn t -> %{t | ref: if(v == "", do: nil, else: v)} end))

  defp event(%{"t" => "op", "op" => "tcoll", "path" => p, "value" => v}, state),
    do: edit_types(state, &Types.update(&1, path(p), fn t -> %{t | collection: v == true} end))

  defp event(%{"t" => "op", "op" => "ckind", "path" => p, "value" => v}, state) do
    edit_types(state, fn types ->
      Types.update(types, path(p), fn t ->
        text = (t.constraint && t.constraint.text) || ""
        %{t | constraint: if(v == "", do: nil, else: %{kind: String.to_existing_atom(v), text: text})}
      end)
    end)
  end

  defp event(%{"t" => "op", "op" => "ctext", "path" => p, "value" => v}, state) do
    state = push_history(state, {:ctext, p}, :merge)
    types = Types.update(state.model.types, path(p), fn t -> %{t | constraint: %{t.constraint | text: v}} end)
    state = %{state | model: %{state.model | types: types}}
    c = Types.get(types, path(p)).constraint
    err = Types.constraint_error(c)

    patch([
      ["html", "#chl-#{p}", DmnSpike.Highlight.html(v, err && err.span)],
      ["html", "#cmsg-#{p}", TypesPanel.message(err)]
      | refresh_ops(state)
    ])

    state
  end

  defp event(_other, state), do: state

  # --- helpers ---------------------------------------------------------------------------

  defp path(p), do: p |> String.split("-") |> Enum.map(&String.to_integer/1)

  @doc false
  # "h-0" (input header), "e-1-0" (entry), "o-1-0" (output), "n-0" (output name): a letter, then numbers
  def table_path(p),
    do: p |> String.split("-") |> Enum.map(fn x -> if x in ["h", "e", "o", "n"], do: x, else: String.to_integer(x) end)

  defp parse_cell(cell) do
    [id, idx] = String.split(cell, ":")
    {id, String.to_integer(idx)}
  end

  # snapshot for undo; `:merge` coalesces consecutive edits with the same key
  defp push_history(state, group, mode \\ :always)
  defp push_history(%{group: key} = state, key, :merge) when key != nil, do: state

  defp push_history(state, group, _mode) do
    state = %{state | past: Enum.take([state.model | state.past], 100), future: [], group: group}
    patch(history_ops(state))
    state
  end

  defp edit_table(state, fun) do
    state = push_history(state, nil)
    state = %{state | model: fun.(state.model)}
    results = Eval.run(state.model)

    patch([
      ["html", "#panel", Panel.render(state.model, state.selected, results, state.dock)] | refresh_ops(state, results)
    ])

    state
  end

  defp edit_types(state, fun) do
    state = push_history(state, nil)
    state = %{state | model: %{state.model | types: fun.(state.model.types)}}
    patch_types(state)
    patch(refresh_ops(state))
    state
  end

  defp select(%{selected: id, sel_edge: nil} = state, {:node, id}), do: state

  defp select(state, target) do
    results = Eval.run(state.model)
    unselect = deselect_ops(state, results)

    {state, ops} =
      case target do
        {:node, id} ->
          {%{state | selected: id, sel_edge: nil},
           [
             [
               "attr",
               ~s|[data-id="#{id}"]|,
               "class",
               Svg.node_class(true, results[id].errors != [], state.model.nodes[id].type)
             ],
             ["html", "#pad-#{id}", Svg.pad(state.model.nodes[id])],
             ["html", "#panel", Panel.render(state.model, id, results, state.dock)]
           ]}

        {:edge, i} ->
          {%{state | sel_edge: i}, [["attr", "#edge-#{i}", "class", Svg.edge_class(true)]]}
      end

    patch(unselect ++ ops)
    state
  end

  defp deselect_ops(state, results) do
    node =
      if state.selected && state.model.nodes[state.selected],
        do: [
          [
            "attr",
            ~s|[data-id="#{state.selected}"]|,
            "class",
            Svg.node_class(false, results[state.selected].errors != [], state.model.nodes[state.selected].type)
          ],
          ["html", "#pad-#{state.selected}", ""]
        ],
        else: []

    edge = if state.sel_edge, do: [["attr", "#edge-#{state.sel_edge}", "class", Svg.edge_class(false)]], else: []
    node ++ edge
  end

  defp show_ac(%{"cell" => cell, "text" => text, "caret" => caret}, state) do
    {id, idx} = parse_cell(cell)
    names = if caret < 0, do: [], else: elem(Autocomplete.suggest(state.model, id, idx, text, caret), 1)
    patch([["html", "#ac-#{id}-#{idx}", Autocomplete.list_html(cell, names)]])
    state
  end

  defp history_ops(state),
    do: [["disabled", "[data-click=undo]", state.past == []], ["disabled", "[data-click=redo]", state.future == []]]

  defp edge_ops(model, id),
    do: for({e, i} <- Model.edges_of(model, id), do: ["html", "#edge-#{i}", Svg.edge(model, e, i)])

  defp patch_types(state), do: patch([["html", "#types", TypesPanel.render(state.model, state.type_sel)]])

  # patches for everything that depends on evaluation: value badges, validation, shown table
  defp refresh_ops(state, results \\ nil, us \\ nil) do
    {us, results} = if results, do: {us || 0, results}, else: :timer.tc(fn -> Eval.run(state.model) end)
    n = state.model.nodes |> Map.values() |> Enum.map(&Model.cell_count/1) |> Enum.sum()

    node_ops =
      for {nid, node} <- state.model.nodes, r = results[nid], reduce: [] do
        acc ->
          [
            ["html", "#nv-#{nid}", if(Model.artifact?(node), do: "", else: Svg.node_value_html(r))],
            ["html", "#tt-#{nid}", if(Model.artifact?(node), do: "", else: Svg.node_title(r))],
            ["attr", ~s|[data-id="#{nid}"]|, "class", Svg.node_class(nid == state.selected, r.errors != [], node.type)]
            | acc
          ] ++ if(node.id == state.selected, do: [["html", "#nerr-#{nid}", Panel.errors_html(r)]], else: [])
      end

    shown =
      case state.selected && results[state.selected] do
        %{cells: cells} ->
          for {c, i} <- Enum.with_index(cells), do: ["html", "#val-#{state.selected}-#{i}", Panel.cell_view(c)]

        _ ->
          []
      end

    table =
      if state.selected && state.model.nodes[state.selected] && Model.kind(state.model.nodes[state.selected]) == :table,
        do: Panel.table_ops(state.model, state.selected, results[state.selected]),
        else: []

    node_ops ++
      shown ++
      table ++ [["html", "#status", "evaluated #{n} cells in #{Float.round(us / 1000, 1)} ms"]] ++ history_ops(state)
  end

  defp current_view(%{view: nil, model: m}), do: View.parse(Svg.viewbox(m))
  defp current_view(%{view: v}), do: v

  defp viewbox(%{view: nil, model: m}), do: Svg.viewbox(m)
  defp viewbox(%{view: v}), do: View.to_string(v)

  defp set_view(state, v) do
    patch([["attr", "#drd", "viewBox", View.to_string(v)]])
    %{state | view: v}
  end

  defp xml_ops(%{tab: "xml"} = state), do: [["html", "#xml", Fmt.esc(Dmn.to_xml(state.model, state.name))]]
  defp xml_ops(_state), do: []

  @dismiss ~s|<button class="x" data-click="dismiss-report" title="Dismiss" aria-label="Dismiss">×</button>|

  @artifact_names %{annotation: "annotation", source: "knowledge source", group: "group"}

  defp artifacts(%{artifacts: map}) when map_size(map) > 0 do
    ", " <> Enum.map_join(Enum.sort(map), ", ", fn {t, n} -> "#{n} #{@artifact_names[t]}#{if n > 1, do: "s"}" end)
  end

  defp artifacts(_), do: ""

  defp report_html(nil), do: ""

  defp report_html({:error, file, msg}),
    do: ~s|<div class="rep"><span class="bad"><b>#{Fmt.esc(file)}</b>: #{Fmt.esc(msg)}</span>#{@dismiss}</div>|

  defp report_html({:ok, file, r}) do
    list = fn map ->
      for({what, n} <- Enum.sort(map), do: "<li>#{if n > 1, do: "#{n} × "}#{Fmt.esc(what)}</li>") |> Enum.join()
    end

    section = fn title, map ->
      if map == %{}, do: "", else: ~s|<p>#{title}</p><ul class="dropped">#{list.(map)}</ul>|
    end

    placed = if r.placed > 0, do: ", #{r.placed} placed automatically (no diagram shape)", else: ""
    lost? = r.dropped != %{}

    details =
      section.("Converted for evaluation (written back as in the file until you edit them):", r.converted) <>
        section.("Kept as in the file (not shown or editable yet):", r.kept) <>
        section.("Lost when saving:", r.dropped)

    verdict =
      cond do
        lost? -> ~s|<span class="bad">Some content will be lost when saving.</span>|
        r.kept == %{} -> ~s|<span class="good">Nothing was lost.</span>|
        true -> ~s|<span class="good">Nothing was lost; some content is kept as in the file.</span>|
      end

    ~s|<div class="rep"><span><b>#{Fmt.esc(file)}</b>: imported #{r.nodes} nodes, #{r.edges} requirements, #{r.types} data types#{artifacts(r)}#{placed}.</span>| <>
      verdict <>
      if(details == "",
        do: "",
        else: ~s|<details#{if lost?, do: " open"}><summary>Details</summary>#{details}</details>|
      ) <>
      @dismiss <> "</div>"
  end

  defp say(state, msg) do
    patch([["html", "#status", Fmt.esc(msg)]])
    state
  end

  defp render_all(state, return_state? \\ false) do
    {us, results} = :timer.tc(fn -> Eval.run(state.model) end)
    selected = if state.model.nodes[state.selected], do: state.selected, else: nil
    state = %{state | selected: selected, group: nil}

    patch(
      [
        ["attr", "#drd", "viewBox", viewbox(state)],
        ["html", "#scene", Svg.scene(state.model, results, state.selected, state.sel_edge)],
        ["html", "#panel", Panel.render(state.model, state.selected, results, state.dock)],
        ["html", "#types", TypesPanel.render(state.model, state.type_sel)],
        ["hidden", "#view-editor", state.tab != "editor"],
        ["hidden", "#view-types", state.tab != "types"],
        ["hidden", "#view-xml", state.tab != "xml"],
        ["attr", "[data-click='tab:editor']", "aria-pressed", to_string(state.tab == "editor")],
        ["attr", "[data-click='tab:types']", "aria-pressed", to_string(state.tab == "types")],
        ["attr", "[data-click='tab:xml']", "aria-pressed", to_string(state.tab == "xml")],
        ["html", "#report", report_html(state.report)]
      ] ++ xml_ops(state) ++ refresh_ops(state, results, us)
    )

    if return_state?, do: state, else: :ok
  end

  defp patch(ops), do: JS.run!(@patch_js, %{ops: ops})
end
