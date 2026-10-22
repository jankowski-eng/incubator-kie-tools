defmodule DmnSpike.Editor do
  @moduledoc """
  Owns the model, history and selection. All logic is Elixir; the JS below only
  forwards DOM events (pointer capture, drag & drop and screen->SVG coordinates
  need the DOM) and applies small `[kind, selector, ...]` patches.
  """
  use GenServer

  alias DmnSpike.{
    Autocomplete,
    Constraint,
    Dmn,
    Eval,
    Fmt,
    Layout,
    Model,
    Panel,
    Problems,
    Svg,
    Types,
    TypesPanel,
    View,
    XmlIndex,
    XmlView
  }

  alias Popcorn.JS

  @name :editor

  @patch_js """
  ({ops}) => {
    // element ids may contain dots (valid in DMN), which a CSS `#id` selector would read as a class
    const find = (sel) => (/^#[^ >[:,+~]+$/.test(sel) ? document.getElementById(sel.slice(1)) : document.querySelector(sel));
    for (const [k, sel, a, b, c] of ops) {
      const el = find(sel);
      if (!el) continue;
      if (k === 'html') el.innerHTML = a;
      else if (k === 'outer') el.outerHTML = a;
      else if (k === 'attr') el.setAttribute(a, b);
      else if (k === 'disabled') el.disabled = a;
      else if (k === 'hidden') el.hidden = a;
      else if (k === 'toggle') el.classList.toggle(a, b);
      else if (k === 'setvalue') el.value = a;
      else if (k === 'focus') { el.focus(); el.select?.(); }
      else if (k === 'scrollto') el.scrollIntoView({block: 'nearest'});
      else if (k === 'xml') window.xmlPane.set(a, b);
      else if (k === 'xsel') window.xmlPane.select(a, b, c);
      else if (k === 'value') { el.value = a; el.setSelectionRange(b, b); el.focus(); }
      else if (k === 'reveal') el.dispatchEvent(new CustomEvent('dmn-reveal', {bubbles: true}));
      else if (k === 'replay') { const box = el.closest('#dock') || el; clearTimeout(el._t); box.classList.remove('closing'); el.classList.remove(a); void el.offsetWidth; el.classList.add(a); el._t = setTimeout(() => el.classList.remove(a), 300); }
      else if (k === 'clear') { const box = el.closest('#dock') || el; clearTimeout(el._t); box.classList.add('closing'); el._t = setTimeout(() => { el.innerHTML = ''; box.classList.remove('closing'); }, 170); }
      else if (k === 'smoothview') window.smoothView(el, a);
    }
    // the create pad sits to the right of the selected node, or to its left when there is no room on the right
    const pad = document.querySelector('.node.sel .pad');
    if (pad) {
      const w = pad.closest('.node').querySelector('.shape').getBBox().width, y = pad.getAttribute('transform').match(/-?[\\d.]+/g)[1];
      pad.setAttribute('transform', `translate(${w + 38} ${y})`);
      if (pad.getBoundingClientRect().right > document.querySelector('.stage').getBoundingClientRect().right - 8)
        pad.setAttribute('transform', `translate(${-38 - +pad.querySelector('.bg').getAttribute('width')} ${y})`);
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
    let mode = null, last = null, moved = false;
    // connecting: dragging from the handle, or (after a plain click on it) a line that follows the pointer until the next click
    let sticky = false, from = null, press = null;
    const scale = () => svg.getScreenCTM().a; // screen px per SVG unit
    // programmatic moves of the camera (zoom buttons, Fit, bringing a node into view) glide; gestures stay immediate
    let viewRaf = 0;
    window.smoothView = (el, target) => {
      cancelAnimationFrame(viewRaf);
      if (matchMedia('(prefers-reduced-motion: reduce)').matches) { el.setAttribute('viewBox', target); return; }
      const nums = (s) => s.split(' ').map(Number), from = nums(el.getAttribute('viewBox')), to = nums(target), t0 = performance.now(), dur = 200;
      const step = (now) => {
        const p = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - p, 3);
        el.setAttribute('viewBox', p < 1 ? from.map((v, i) => v + (to[i] - v) * e).join(' ') : target);
        if (p < 1) viewRaf = requestAnimationFrame(step);
      };
      viewRaf = requestAnimationFrame(step);
    };
    // the expression panel floats over the canvas: pan a newly selected node out from under it
    svg.addEventListener('dmn-reveal', (e) => {
      const p = $('#panel').getBoundingClientRect(), r = e.target.getBoundingClientRect();
      if (p.height && r.bottom > p.top - 16) ed({t: 'pan', dx: 0, dy: (r.bottom - p.top + 32) / scale(), smooth: true});
    });
    svg.addEventListener('wheel', (e) => { e.preventDefault(); cancelAnimationFrame(viewRaf); const p = at(e); ed({t: 'zoom', f: Math.exp(e.deltaY * 0.0015), x: p.x, y: p.y}); }, {passive: false});
    // the hovered node goes to the front, so its connect handle is never hidden behind a neighbour
    svg.addEventListener('pointerover', (e) => {
      const g = e.target.closest?.('.node');
      // a group stays behind what it groups, so it is never raised
      if (g && !g.classList.contains('group') && !mode && !sticky && g.parentNode.lastElementChild !== g) g.parentNode.appendChild(g);
    });
    svg.addEventListener('pointerdown', (e) => {
      cancelAnimationFrame(viewRaf);
      if (sticky) {
        const hit = e.target.closest('[data-id]');
        sticky = false;
        ed({t: 'cend', to: hit && hit.dataset.id !== from ? hit.dataset.id : null});
        return;
      }
      const h = e.target.closest('[data-handle]'), g = e.target.closest('[data-id]'), l = e.target.closest('[data-edge]');
      const mk = e.target.closest('[data-create]');
      if (e.target.closest('[data-info]')) ed({t: 'click', what: 'dock:props'});
      if (mk) ed({t: 'create', kind: mk.dataset.create});
      else if (e.target.closest('[data-typepill]')) ed({t: 'focus_type'});
      else if (e.target.closest('[data-del]')) ed({t: 'delete'});
      else if (e.target.closest('[data-resize]')) { mode = 'resize'; svg.setPointerCapture(e.pointerId); ed({t: 'rstart', id: e.target.closest('[data-resize]').dataset.resize}); }
      else if (h) { mode = 'connect'; from = h.dataset.handle; press = {x: e.clientX, y: e.clientY}; svg.setPointerCapture(e.pointerId); ed({t: 'cstart', id: from}); }
      else if (g) { mode = 'drag'; svg.setPointerCapture(e.pointerId); const p = at(e); ed({t: 'down', id: g.dataset.id, x: p.x, y: p.y}); }
      else if (l) ed({t: 'edge', i: Number(l.dataset.edge)});
      else { mode = 'pan'; moved = false; last = {x: e.clientX, y: e.clientY}; svg.setPointerCapture(e.pointerId); }
    });
    // sent as an event so it is handled after the selection has re-rendered the panel
    const rename = () => ed({t: 'rename'});
    svg.addEventListener('pointermove', (e) => {
      if (sticky) { const p = at(e); ed({t: 'cmove', x: p.x, y: p.y}); return; }
      if (!mode) return;
      if (mode === 'pan') {
        if (Math.abs(e.clientX - last.x) + Math.abs(e.clientY - last.y) < 1) return;
        moved = true;
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
      if (mode === 'pan' && !moved) ed({t: 'deselect'});
      if (mode === 'connect' && Math.hypot(e.clientX - press.x, e.clientY - press.y) < 5) {
        sticky = true; // a click, not a drag: keep the connection open
      } else if (mode === 'connect') {
        const hit = document.elementFromPoint(e.clientX, e.clientY)?.closest('[data-id]');
        ed({t: 'cend', to: hit ? hit.dataset.id : null});
      }
      mode = null;
    });

    // double click: rename in place with an input laid over the node's name; the value line below stays as it is
    svg.addEventListener('dblclick', (e) => {
      // pointer capture retargets the event to the svg, so look the node up by position
      const g = document.elementFromPoint(e.clientX, e.clientY)?.closest('[data-id]');
      if (!g || document.elementFromPoint(e.clientX, e.clientY).closest('[data-handle]')) return;
      // an annotation's text is not an SVG <text>: it is edited in the properties field, as F2 does
      if (!g.querySelector('text')) { rename(); return; }
      const id = g.dataset.id, s = scale(), box = $('.stage').getBoundingClientRect(), r = g.querySelector('.shape').getBoundingClientRect(); // not the group: it includes the handle
      const input = document.createElement('input');
      input.className = 'rename';
      input.value = g.querySelector('text').textContent;
      input.setAttribute('aria-label', 'Name');
      Object.assign(input.style, {left: r.left - box.left + 8 * s + 'px', top: r.top - box.top + 8 * s + 'px', width: r.width - 16 * s + 'px', height: 26 * s + 'px', fontSize: 12 * s + 'px'});
      const done = () => input.remove();
      input.addEventListener('input', () => ed({t: 'op', op: 'nname', path: null, id, kind: 'canvas', value: input.value}));
      input.addEventListener('keydown', (k) => { if (k.key === 'Enter' || k.key === 'Escape') { k.stopPropagation(); input.blur(); } });
      input.addEventListener('blur', done);
      $('.stage').appendChild(input);
      input.focus();
      input.select();
    });

    // palette: drag new elements onto the canvas
    $('#palette').addEventListener('dragstart', (e) => e.dataTransfer.setData('text/plain', e.target.closest('[data-kind]').dataset.kind));
    $('.stage').addEventListener('dragover', (e) => e.preventDefault());
    $('.stage').addEventListener('drop', (e) => {
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
    const step = (el, d) => {
      let next;
      if (el.dataset.op === 'dtnote') {
        next = panel.querySelector(`[data-op=dtnote][data-id="${el.dataset.id}"][data-path="${+el.dataset.path + d}"]`);
      } else if (el.dataset.cell) {
        const [id, idx] = el.dataset.cell.split(':');
        next = panel.querySelector(`[data-cell="${id}:${+idx + d}"]`);
      } else {
        const [k, r, i] = el.dataset.path.split('-');
        if (k === 'e' || k === 'o') next = panel.querySelector(`[data-op=dtcell][data-id="${el.dataset.id}"][data-path="${k}-${+r + d}-${i}"]`);
      }
      next?.focus();
    };
    panel.addEventListener('input', (e) => { if (e.target.dataset.cell) ed(cell(e, 'cell')); });
    panel.addEventListener('focusin', (e) => { if (e.target.dataset.cell) ed(cell(e, 'focus')); });
    panel.addEventListener('focusout', (e) => { if (e.target.dataset.cell) ed({...cell(e, 'focus'), caret: -1}); });
    panel.addEventListener('keyup', (e) => {
      if (e.target.dataset.cell && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) ed(cell(e, 'focus'));
    });
    panel.addEventListener('keydown', (e) => {
      const d = e.target.dataset;
      if (e.key === 'Enter' && (d.cell || d.op === 'dtcell' || d.op === 'dtnote')) {
        e.preventDefault();
        step(e.target, e.shiftKey ? -1 : 1);
      }
      if (!e.target.dataset.cell) return;
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

    // XML inspector: a click on the code (not the end of a text selection) asks which element it is in
    $('#xcode').addEventListener('click', (e) => {
      if (!getSelection().isCollapsed || e.target.closest('.xg')) return;
      const l = e.target.closest('.xl');
      if (l) ed({t: 'xclick', line: Number(l.dataset.n)});
    });

    // data types tab: tree keyboard, inline edits (Enter keeps, Esc cancels), chips, double click to rename
    const types = $('#types');
    let lastDown = null;
    types.addEventListener('mousedown', (e) => { lastDown = e.target; });
    // clicking into an inline edit must not count as a click on its row
    types.addEventListener('click', (e) => { if (e.target.closest('[data-tedit]')) e.stopPropagation(); }, true);
    types.addEventListener('keydown', (e) => {
      const t = e.target;
      if (t.dataset.tedit !== undefined) {
        if (e.key === 'Enter' || e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); ed({t: 'tedit', ok: e.key === 'Enter'}); }
        return;
      }
      if (t.dataset.op === 'citem') {
        if (e.key === 'Enter') { e.preventDefault(); ed({t: 'op', op: 'citem', path: t.dataset.path, id: null, kind: 'enter', value: t.value}); }
        return;
      }
      if (t.id === 'ttree') {
        if (['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'Enter', 'F2', 'Delete', 'Backspace'].includes(e.key)) {
          e.preventDefault(); e.stopPropagation();
          ed({t: 'tkey', key: e.key});
        }
        return;
      }
      if (t.closest('#tinspector') && (e.key === 'Escape' || (e.key === 'Enter' && t.matches('input:not([type=checkbox])')))) {
        e.preventDefault(); e.stopPropagation();
        $('#ttree').focus();
      }
    });
    // leaving an inline edit commits it, unless the user is clicking a row (that click commits and selects)
    types.addEventListener('focusout', (e) => {
      if (e.target.dataset.tedit === undefined) return;
      if (lastDown?.closest?.('.trow') && !lastDown.closest('[data-tedit]')) return;
      ed({t: 'tedit', ok: true});
    });
    types.addEventListener('dblclick', (e) => {
      const n = e.target.closest('[data-tname]');
      if (n) ed({t: 'click', what: 'trename:' + n.dataset.tname});
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
      if (b) {
        const msg = {t: 'click', what: b.dataset.click};
        // the starters of the empty diagram put the node where the middle of the canvas is on screen
        if (msg.what.startsWith('empty-add:')) { const r = $('.stage').getBoundingClientRect(), p = at({clientX: r.left + r.width / 2, clientY: r.top + r.height / 2}); msg.x = p.x; msg.y = p.y; }
        ed(msg);
      }
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
      else if (k === 'escape') { sticky = false; ed({t: 'deselect'}); }
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
      dock: "expr",
      tab: "editor",
      report: nil,
      name: "Popcorn spike",
      upload: nil,
      view: nil,
      toast: 0,
      # Data types tab: selection, folded rows, search, inspector (:auto opens with the first selection), inline edit, FEEL-mode paths
      tsel: nil,
      tclosed: MapSet.new(),
      tq: "",
      tinsp: :auto,
      tedit: nil,
      tadv: MapSet.new(),
      # XML inspector: open?, the document and its ranges as last shown, a refresh is pending, build time (ms), scroll on next refresh
      xopen: false,
      xml: nil,
      xdirty: false,
      xtimer: nil,
      xms: 0,
      xscroll: false,
      # the "empty diagram" card: shown while there are no nodes, until dismissed (it comes back for the next empty one)
      hint: true
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
    {:noreply, state |> then(&event(msg, &1)) |> then(&sync_xml(state, &1, msg))}
  rescue
    e ->
      {:noreply, say(state, "internal error: " <> inspect(e, limit: 4, printable_limit: 300), :error)}
  catch
    kind, reason ->
      {:noreply, say(state, "internal error: " <> inspect({kind, reason}, limit: 4, printable_limit: 300), :error)}
  end

  # the inspector shows the document as of the last refresh; a burst of changes becomes one rebuild
  def handle_info(:xml_refresh, %{xopen: true} = state) do
    state = xml_build(%{state | xtimer: nil})
    patch([xml_op(state) | xsel_ops(state, state.xscroll)])
    {:noreply, %{state | xscroll: false}}
  rescue
    e -> {:noreply, say(state, "internal error: " <> inspect(e, limit: 4, printable_limit: 300), :error)}
  end

  def handle_info(:xml_refresh, state), do: {:noreply, %{state | xtimer: nil}}

  # hide a toast unless a newer one replaced it
  def handle_info({:clear_toast, n}, %{toast: n} = state) do
    patch([["hidden", "#toast", true]])
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

  defp event(%{"t" => "pan", "dx" => dx, "dy" => dy} = msg, state),
    do: set_view(state, View.pan(current_view(state), dx, dy), msg["smooth"] == true)

  defp event(%{"t" => "zoom", "f" => f, "x" => x, "y" => y}, state),
    do: set_view(state, View.zoom(current_view(state), f, x, y))

  defp event(%{"t" => "click", "what" => w}, state) when w in ["zoom-in", "zoom-out"] do
    v = current_view(state)
    {cx, cy} = View.center(v)
    set_view(state, View.zoom(v, if(w == "zoom-in", do: 0.8, else: 1.25), cx, cy), true)
  end

  defp event(%{"t" => "click", "what" => "fit"}, state) do
    state = %{state | view: nil}
    patch([["smoothview", "#drd", viewbox(state)]])
    state
  end

  # `connect` is `{from, valid_targets, {hot_node, hot_side}}` while a connection is being dragged
  defp event(%{"t" => "cstart", "id" => from}, state) do
    targets = for {id, _} <- state.model.nodes, match?({:ok, _}, Model.connect(state.model, from, id)), do: id
    patch(connect_ops([from | targets], from, true))
    %{state | connect: {from, targets, {nil, nil}}}
  end

  defp event(%{"t" => "cmove", "x" => x, "y" => y}, %{connect: {from, targets, {hot, side}}} = state)
       when from != nil do
    over = Enum.find(targets, fn id -> inside?(state.model.nodes[id], x, y) end)
    over_side = over && Svg.nearest_side(state.model.nodes[over], {x, y})

    patch(
      if({over, over_side} != {hot, side},
        do: anchor_ops(hot, side, false) ++ anchor_ops(over, over_side, true),
        else: []
      ) ++
        [["html", "#preview", Svg.preview(state.model, from, over && state.model.nodes[over], {x, y})]]
    )

    %{state | connect: {from, targets, {over, over_side}}}
  end

  defp event(%{"t" => "cend", "to" => to}, %{connect: {from, targets, {hot, side}}} = state) when from != nil do
    patch([["html", "#preview", ""] | anchor_ops(hot, side, false) ++ connect_ops([from | targets], from, false)])
    state = %{state | connect: nil}
    # the side only counts when the drop is on the node that was highlighted
    side = if to == hot, do: side

    with true <- is_binary(to), {:ok, model} <- Model.connect(state.model, from, to, side) do
      state |> push_history(nil) |> Map.put(:model, model) |> render_all(true)
    else
      {:error, reason} -> say(state, "✗ #{reason}", :error)
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

  defp event(%{"t" => "click", "what" => "problem-node:" <> id}, state) do
    if state.model.nodes[id],
      do: render_all(%{state | tab: "editor", selected: id, sel_edge: nil}, true),
      else: state
  end

  defp event(%{"t" => "click", "what" => "problem-type:" <> i}, state),
    do: render_all(%{state | tab: "types", type_sel: String.to_integer(i)}, true)

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

  defp event(%{"t" => "deselect"}, %{connect: {_, _, _}} = state), do: event(%{"t" => "cend", "to" => nil}, state)

  defp event(%{"t" => "deselect"}, state) do
    patch([["clear", "#panel"] | deselect_ops(state, Eval.run(state.model))])
    %{state | selected: nil, sel_edge: nil}
  end

  defp event(%{"t" => "click", "what" => "deselect"}, state), do: event(%{"t" => "deselect"}, state)

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

  # a blank model; the previous one stays one Undo away
  defp event(%{"t" => "click", "what" => "new-dmn"}, state) do
    state = push_history(state, nil)

    state = %{
      state
      | model: %Model{},
        selected: nil,
        sel_edge: nil,
        tsel: nil,
        tedit: nil,
        tclosed: MapSet.new(),
        tq: "",
        tadv: MapSet.new(),
        report: nil,
        view: nil,
        name: "Untitled",
        hint: true,
        tab: "editor",
        connect: nil
    }

    state |> render_all(true) |> say("New DMN created. Undo brings the previous one back.")
  end

  defp event(%{"t" => "click", "what" => "empty-dismiss"}, state), do: render_all(%{state | hint: false}, true)

  # first node from the empty-diagram card, in the middle of what is on screen
  defp event(%{"t" => "click", "what" => "empty-add:" <> what} = msg, state) do
    {cx, cy} =
      {msg["x"] || elem(View.center(current_view(state)), 0), msg["y"] || elem(View.center(current_view(state)), 1)}

    # keep the camera where it is, so the node stays in the middle instead of the view being fitted around it
    state = %{state | view: current_view(state)}
    state = push_history(state, nil)
    {model, id} = Model.add_node(state.model, if(what == "input", do: "input", else: "decision"), cx, cy)
    model = if what == "table", do: Model.set_expr_kind(model, id, :table), else: model
    render_all(%{state | model: model, selected: id, sel_edge: nil}, true)
  end

  defp event(%{"t" => "click", "what" => "export"}, state) do
    file = (state.name |> String.replace(~r/[^\w\- ]+/u, "") |> String.trim() |> String.replace(" ", "-")) <> ".dmn"
    JS.run!(@download_js, %{xml: Dmn.to_xml(state.model, state.name), name: file})
    say(state, "exported #{file}")
  end

  defp event(%{"t" => "click", "what" => "tab:" <> tab}, state) when tab in ["editor", "types"],
    do: render_all(%{state | tab: tab}, true)

  defp event(%{"t" => "click", "what" => "xml-toggle"}, %{xopen: true} = state) do
    patch([["toggle", "#xmlpane", "open", false], ["attr", "[data-click=xml-toggle]", "aria-pressed", "false"]])
    %{state | xopen: false, xml: nil, xdirty: false}
  end

  defp event(%{"t" => "click", "what" => "xml-toggle"}, state) do
    state = xml_build(%{state | xopen: true})

    patch([
      ["toggle", "#xmlpane", "open", true],
      ["attr", "[data-click=xml-toggle]", "aria-pressed", "true"],
      xml_op(state) | xsel_ops(state, true)
    ])

    state
  end

  # a click in the code selects the most specific element it is in; the code is not scrolled, the user is reading it
  defp event(%{"t" => "xclick", "line" => line}, %{xml: %{}} = state) do
    case XmlView.key_at(state.xml, line) do
      nil -> state
      key -> select_key(state, key)
    end
  end

  defp event(%{"t" => "xclick"}, state), do: state
  defp event(%{"t" => "click", "what" => w}, state) when w in ["undo", "redo"], do: event(%{"t" => w}, state)

  # --- data types tab ------------------------------------------------------------------------

  defp event(%{"t" => "click", "what" => "add-type"}, state) do
    name = unique_name("tNewType", Enum.map(state.model.types, & &1.name))
    state = push_history(state, nil)
    state = %{state | model: %{state.model | types: state.model.types ++ [Types.new_type(name)]}}
    start_rename(state, TypesPanel.path_str([length(state.model.types) - 1]))
  end

  defp event(%{"t" => "click", "what" => "tadd-child:" <> p}, state) do
    path = path(p)
    name = unique_name("field", Enum.map(Types.fetch(state.model.types, path).components, & &1.name))
    state = push_history(state, nil)
    types = Types.add_child(state.model.types, path, Types.new_type(name))
    child = path ++ [length(Types.fetch(types, path).components) - 1]
    state = %{state | model: %{state.model | types: types}, tclosed: MapSet.delete(state.tclosed, p)}
    start_rename(state, TypesPanel.path_str(child))
  end

  defp event(%{"t" => "click", "what" => "tdel:" <> p}, state) do
    path = path(p)
    t = Types.fetch(state.model.types, path)
    usage = if length(path) == 1, do: Types.usages(state.model, t.name), else: %{nodes: [], types: []}

    if usage.nodes == [] and usage.types == [] do
      state = push_history(state, nil)
      sel = if length(path) > 1, do: TypesPanel.path_str(Enum.drop(path, -1))
      state = %{state | model: %{state.model | types: Types.delete(state.model.types, path)}, tsel: sel, tedit: nil}
      patch_types(state)
      patch(refresh_ops(state))
      state
    else
      users = Enum.take(usage.nodes ++ usage.types, 3) |> Enum.join(", ")

      say(
        state,
        "✗ #{t.name} is used by #{users}#{if length(usage.nodes ++ usage.types) > 3, do: "…"}. Change those first.",
        :error
      )
    end
  end

  # a click on a row ends any inline edit first, then selects
  defp event(%{"t" => "click", "what" => "tsel:" <> _ = msg}, %{tedit: %{}} = state) do
    state = event(%{"t" => "tedit", "ok" => true}, state)
    event(msg, state)
  end

  defp event(%{"t" => "click", "what" => "tsel:" <> p}, %{tsel: p} = state), do: state
  defp event(%{"t" => "click", "what" => "tsel:" <> p}, state), do: select_type(state, p)

  defp event(%{"t" => "click", "what" => "ttoggle:" <> p}, state) do
    closed =
      if MapSet.member?(state.tclosed, p), do: MapSet.delete(state.tclosed, p), else: MapSet.put(state.tclosed, p)

    state = %{state | tclosed: closed}
    patch([["html", "#ttree", TypesPanel.tree(state.model, tui(state))]])
    state
  end

  defp event(%{"t" => "click", "what" => "ttype:" <> p}, %{tsel: p, tedit: nil} = state),
    do: start_edit(state, p, :type)

  defp event(%{"t" => "click", "what" => "ttype:" <> p}, state),
    do: event(%{"t" => "click", "what" => "tsel:" <> p}, state)

  defp event(%{"t" => "click", "what" => "trename:" <> p}, state), do: start_edit(select_type(state, p), p, :name)

  defp event(%{"t" => "click", "what" => "tinsp-toggle"}, state) do
    state = %{state | tinsp: not tui(state).insp}
    patch_types(state)
    state
  end

  defp event(%{"t" => "click", "what" => "cmode:" <> rest}, state) do
    [p, mode] = String.split(rest, ":")
    path = path(p)
    t = Types.fetch(state.model.types, path)
    c = t.constraint
    form = c && Constraint.parse(c.text, c.kind)
    locked? = form == :advanced

    new =
      case mode do
        "none" -> {:set, nil}
        "feel" -> {:set, c || %{kind: :expression, text: ""}}
        _ when locked? -> :ignore
        "cmp" -> visual(form, :cmp, {:cmp, ">=", "0"})
        "interval" -> visual(form, :interval, {:interval, "[", "0", "100", "]"})
        "list" -> visual(form, :list, {:list, []})
      end

    case new do
      :ignore ->
        state

      {:set, constraint} ->
        adv = if mode == "feel", do: MapSet.put(state.tadv, p), else: MapSet.delete(state.tadv, p)
        state = %{state | tadv: adv}
        set_constraint(state, path, constraint)

      {:form, f} ->
        state = %{state | tadv: MapSet.delete(state.tadv, p)}
        set_constraint(state, path, %{kind: Constraint.kind(f), text: Constraint.build(f)})
    end
  end

  defp event(%{"t" => "click", "what" => "cdel:" <> rest}, state) do
    [p, i] = String.split(rest, ":")
    path = path(p)
    c = Types.fetch(state.model.types, path).constraint
    {:list, items} = Constraint.parse(c.text, c.kind)

    set_constraint(state, path, %{
      kind: :enumeration,
      text: Constraint.build({:list, List.delete_at(items, String.to_integer(i))})
    })
  end

  # keyboard on the tree: arrows move and fold, Enter/F2 rename, Delete removes
  defp event(%{"t" => "tkey", "key" => key}, state) do
    ui = tui(state)
    rows = for {p, _, t} <- TypesPanel.visible(state.model, ui), do: {TypesPanel.path_str(p), p, t}
    idx = Enum.find_index(rows, fn {s, _, _} -> s == state.tsel end)
    last = length(rows) - 1

    case key do
      "ArrowDown" ->
        move_sel(state, rows, min((idx || -1) + 1, last))

      "ArrowUp" ->
        move_sel(state, rows, max((idx || 1) - 1, 0))

      "Home" ->
        move_sel(state, rows, 0)

      "End" ->
        move_sel(state, rows, last)

      "ArrowRight" ->
        key_right(state, rows, idx)

      "ArrowLeft" ->
        key_left(state, rows, idx)

      k when k in ["Enter", "F2"] and idx != nil ->
        start_edit(state, state.tsel, :name)

      k when k in ["Delete", "Backspace"] and idx != nil ->
        event(%{"t" => "click", "what" => "tdel:" <> state.tsel}, state)

      _ ->
        state
    end
  end

  # end of an inline edit: Enter/blur keep it, Escape puts the name back as it was
  defp event(%{"t" => "tedit"}, %{tedit: nil} = state), do: state

  defp event(%{"t" => "tedit", "ok" => ok}, %{tedit: %{field: field, model0: model0}} = state) do
    state =
      if ok == false and field == :name do
        past =
          case state.past do
            [^model0 | rest] -> rest
            other -> other
          end

        %{state | model: model0, past: past, group: nil}
      else
        state
      end

    state = %{state | tedit: nil}
    patch_types(state)
    patch([["focus", "#ttree"] | history_ops(state)] ++ refresh_ops(state))
    state
  end

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

  defp event(%{"t" => "op", "op" => "nname", "id" => id, "value" => v} = msg, state) do
    kind = msg["kind"]
    state = push_history(state, {:nname, id}, :merge)
    state = %{state | model: Model.rename(state.model, id, v)}
    sync = if kind == "canvas", do: [["setvalue", ~s|[data-op="nname"][data-id="#{id}"]|, v]], else: []
    patch([["html", "#nm-#{id}", Fmt.esc(v)] | sync ++ refresh_ops(state)])
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
    patch([["html", "#note-#{id}-#{r}", Fmt.esc(v) <> "\u200b"]])
    %{state | model: Model.set_note(state.model, id, String.to_integer(r), v)}
  end

  defp event(%{"t" => "op", "op" => "dttype", "id" => id, "path" => p, "value" => v}, state) do
    state = push_history(state, nil)
    [kind, i] = String.split(p, "-")
    kind = if kind == "h", do: :input, else: :output
    %{state | model: Model.set_col_type(state.model, id, kind, String.to_integer(i), if(v == "", do: nil, else: v))}
  end

  defp event(%{"t" => "op", "op" => "dthp", "id" => id, "value" => v}, state) do
    state = push_history(state, nil)
    state = %{state | model: Model.set_hit_policy(state.model, id, v)}
    patch(refresh_ops(state))
    state
  end

  defp event(%{"t" => "click", "what" => "dt-ins-rule:" <> rest}, state), do: insert(state, &Model.insert_rule/3, rest)

  defp event(%{"t" => "click", "what" => "dt-ins-input:" <> rest}, state),
    do: insert(state, &Model.insert_input/3, rest)

  defp event(%{"t" => "click", "what" => "dt-ins-output:" <> rest}, state),
    do: insert(state, &Model.insert_output/3, rest)

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

  defp event(%{"t" => "op", "op" => "tsearch", "value" => v}, state) do
    state = %{state | tq: v}
    patch([["html", "#ttree", TypesPanel.tree(state.model, tui(state))]])
    state
  end

  defp event(%{"t" => "op", "op" => "tname", "kind" => "change"}, state), do: state

  defp event(%{"t" => "op", "op" => "tname", "path" => p, "value" => v}, state) do
    path = path(p)
    state = push_history(state, {:tname, p}, :merge)

    model =
      case path do
        [i] -> Types.rename_top(state.model, i, v)
        _ -> %{state.model | types: Types.update(state.model.types, path, &%{&1 | name: v})}
      end

    state = %{state | model: model}
    err = Types.name_error(model.types, path)

    # while typing in the tree itself its input must survive, so only the other views are refreshed
    tree = if state.tedit, do: [], else: [["html", "#ttree", TypesPanel.tree(model, tui(state))]]

    patch(
      tree ++ [["html", "#ititle-#{p}", Fmt.esc(v)], ["html", "#tmsg-#{p}", Fmt.esc(err || "")]] ++ refresh_ops(state)
    )

    state
  end

  defp event(%{"t" => "op", "op" => "tref", "path" => p, "value" => v}, state) do
    state = %{state | tedit: nil}
    state = edit_types(state, &Types.update(&1, path(p), fn t -> %{t | ref: if(v == "", do: nil, else: v)} end))
    patch([["focus", "#ttree"]])
    state
  end

  defp event(%{"t" => "op", "op" => "tcoll", "path" => p, "value" => v}, state),
    do: edit_types(state, &Types.update(&1, path(p), fn t -> %{t | collection: v == true} end))

  defp event(%{"t" => "op", "op" => "ckind", "path" => p, "value" => v}, state) do
    edit_types(state, fn types ->
      Types.update(types, path(p), fn t -> %{t | constraint: %{t.constraint | kind: String.to_existing_atom(v)}} end)
    end)
  end

  defp event(%{"t" => "op", "op" => "ctext", "path" => p, "value" => v}, state) do
    state = push_history(state, {:ctext, p}, :merge)
    types = Types.update(state.model.types, path(p), fn t -> %{t | constraint: %{t.constraint | text: v}} end)
    state = %{state | model: %{state.model | types: types}}
    err = Types.constraint_error(Types.fetch(types, path(p)).constraint)

    patch([
      ["html", "#chl-#{p}", DmnSpike.Highlight.html(v, err && err.span)],
      ["html", "#cmsg-#{p}", TypesPanel.message(err)],
      ["html", "#trow-#{p} .tcons", TypesPanel.summary(Types.fetch(types, path(p)))]
      | refresh_ops(state)
    ])

    state
  end

  # the visual constraint editors: each control rewrites the canonical text from the parsed form
  defp event(%{"t" => "op", "op" => op, "path" => p, "value" => v}, state)
       when op in ["cop", "cval", "clo", "ca", "cb", "chi"] do
    path = path(p)
    c = Types.fetch(state.model.types, path).constraint

    form =
      case {op, Constraint.parse(c.text, c.kind)} do
        {"cop", {:cmp, _, lit}} -> {:cmp, v, lit}
        {"cval", {:cmp, o, _}} -> {:cmp, o, String.trim(v)}
        {"clo", {:interval, _, a, b, hi}} -> {:interval, v, a, b, hi}
        {"ca", {:interval, lo, _, b, hi}} -> {:interval, lo, String.trim(v), b, hi}
        {"cb", {:interval, lo, a, _, hi}} -> {:interval, lo, a, String.trim(v), hi}
        {"chi", {:interval, lo, a, b, _}} -> {:interval, lo, a, b, v}
        _ -> nil
      end

    constraint = form && %{kind: Constraint.kind(form), text: Constraint.build(form)}

    # the `change` that follows an `input` repeats it: no new history step
    if constraint && constraint != c do
      state = push_history(state, {:cvis, p, op}, :merge)
      types = Types.update(state.model.types, path, &%{&1 | constraint: constraint})
      state = %{state | model: %{state.model | types: types}}

      patch([
        ["html", "#cmsg-#{p}", TypesPanel.message(Types.constraint_error(constraint))],
        ["html", "#trow-#{p} .tcons", TypesPanel.summary(Types.fetch(types, path))] | refresh_ops(state)
      ])

      state
    else
      state
    end
  end

  defp event(%{"t" => "op", "op" => "citem", "path" => p, "value" => v}, state) do
    path = path(p)
    t = Types.fetch(state.model.types, path)
    lit = Constraint.literal(Types.base(state.model, t), v)

    with true <- String.trim(v) != "",
         {:list, items} <- Constraint.parse(t.constraint.text, t.constraint.kind),
         false <- lit in items do
      state = set_constraint(state, path, %{kind: :enumeration, text: Constraint.build({:list, items ++ [lit]})})
      patch([["setvalue", ~s|[data-op="citem"]|, ""], ["focus", ~s|[data-op="citem"]|]])
      state
    else
      _ -> state
    end
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

  defp node_sel(nil), do: "#none"
  defp node_sel(id), do: ~s|[data-id="#{id}"]|

  defp connect_ops([from | targets], from, on?),
    do:
      [["toggle", "#drd", "connecting", on?], ["toggle", node_sel(from), "src", on?]] ++
        for(id <- targets, do: ["toggle", node_sel(id), "target", on?])

  # a margin of 14 reaches the anchors, which sit on the border and half outside it
  defp inside?(n, x, y), do: x >= n.x - 14 and x <= n.x + n.w + 14 and y >= n.y - 14 and y <= n.y + n.h + 14

  defp anchor_ops(nil, _side, _on?), do: []

  defp anchor_ops(id, side, on?),
    do: [["toggle", node_sel(id), "hot", on?], ["toggle", ~s|[data-id="#{id}"] [data-side="#{side}"]|, "hot", on?]]

  defp insert(state, fun, "" <> rest) do
    [id, at] = String.split(rest, ":")
    edit_table(state, &fun.(&1, id, String.to_integer(at)))
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

  defp set_constraint(state, path, constraint) do
    edit_types(state, &Types.update(&1, path, fn t -> %{t | constraint: constraint} end))
  end

  defp visual({kind, _, _} = form, kind, _default), do: {:form, form}
  defp visual({kind, _, _, _, _} = form, kind, _default), do: {:form, form}
  defp visual({kind, _} = form, kind, _default), do: {:form, form}
  defp visual(_form, _kind, default), do: {:form, default}

  # the view state the Data types panel renders from
  defp tui(state) do
    sel_ok? = state.tsel != nil and Types.fetch(state.model.types, path(state.tsel)) != nil
    sel = if sel_ok?, do: state.tsel

    %{
      sel: sel,
      closed: state.tclosed,
      q: state.tq,
      insp: state.tinsp == true or (state.tinsp == :auto and sel != nil),
      edit: state.tedit && {state.tedit.path, state.tedit.field},
      adv: state.tadv
    }
  end

  defp types_ops(state) do
    ui = tui(state)

    [
      ["html", "#ttree", TypesPanel.tree(state.model, ui)],
      ["html", "#tinspector", TypesPanel.inspector(state.model, ui)],
      ["attr", "#tview", "data-inspector", if(ui.insp, do: "open", else: "closed")],
      ["attr", "[data-click=tinsp-toggle].tb", "aria-pressed", to_string(ui.insp)]
    ]
  end

  defp patch_types(state), do: patch(types_ops(state))

  defp unique_name(base, taken),
    do: Enum.find([base | for(i <- 2..99, do: base <> Integer.to_string(i))], &(&1 not in taken))

  defp select_type(state, p) do
    state = %{state | tsel: p}
    patch_types(state)
    patch([["scrollto", "#trow-#{p}"]])
    state
  end

  defp move_sel(state, [], _i), do: state

  defp move_sel(state, rows, i) do
    {p, _, _} = Enum.at(rows, i)
    select_type(state, p)
  end

  # Right: open a closed structure, else go to its first field
  defp key_right(state, rows, idx) when idx != nil do
    {p, _, t} = Enum.at(rows, idx)

    cond do
      t.components == [] -> state
      MapSet.member?(state.tclosed, p) -> event(%{"t" => "click", "what" => "ttoggle:" <> p}, state)
      true -> move_sel(state, rows, min(idx + 1, length(rows) - 1))
    end
  end

  defp key_right(state, _rows, _idx), do: state

  # Left: close an open structure, else go to the parent
  defp key_left(state, rows, idx) when idx != nil do
    {p, path, t} = Enum.at(rows, idx)

    cond do
      t.components != [] and not MapSet.member?(state.tclosed, p) ->
        event(%{"t" => "click", "what" => "ttoggle:" <> p}, state)

      length(path) > 1 ->
        select_type(state, TypesPanel.path_str(Enum.drop(path, -1)))

      true ->
        state
    end
  end

  defp key_left(state, _rows, _idx), do: state

  # an inline edit of the name or the type of row `p`; Escape later restores `model0`
  defp start_edit(state, p, field) do
    state = %{state | tedit: %{path: p, field: field, model0: state.model}}
    patch_types(state)
    patch([["focus", "#trow-#{p} .tedit"], ["scrollto", "#trow-#{p}"]])
    state
  end

  defp start_rename(state, p) do
    patch(refresh_ops(state))
    start_edit(%{state | tsel: p}, p, :name)
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
             ["html", "#panel", Panel.render(state.model, id, results, state.dock)],
             ["replay", "#panel", "swap"],
             ["reveal", ~s|[data-id="#{id}"]|]
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

    problems = Problems.list(state.model, results)
    {label, level} = Problems.summary(problems)

    problem_ops = [
      ["html", "#problems-btn", label],
      ["attr", "#problems-btn", "data-level", level],
      ["html", "#problems-list", Problems.html(problems, 100)]
    ]

    node_ops ++
      shown ++
      table ++
      problem_ops ++
      [["html", "#status", "evaluated #{n} cells in #{Float.round(us / 1000, 1)} ms"]] ++ history_ops(state)
  end

  defp current_view(%{view: nil, model: m}), do: View.parse(Svg.viewbox(m))
  defp current_view(%{view: v}), do: v

  defp viewbox(%{view: nil, model: m}), do: Svg.viewbox(m)
  defp viewbox(%{view: v}), do: View.to_string(v)

  defp set_view(state, v, smooth? \\ false) do
    patch([
      [
        if(smooth?, do: "smoothview", else: "attr"),
        "#drd",
        if(smooth?, do: View.to_string(v), else: "viewBox"),
        View.to_string(v)
      ]
    ])

    %{state | view: v}
  end

  # --- XML inspector -------------------------------------------------------------------------

  defp xml_build(state) do
    {us, x} = :timer.tc(fn -> XmlIndex.build(state.model, state.name) end)
    %{state | xml: x, xdirty: false, xms: div(us, 1000)}
  end

  defp xml_op(%{xml: x}), do: ["xml", "#xcode", XmlView.html(x), "#{length(x.lines)} lines"]

  # what the user has selected, in the terms of the document: a node, a requirement, or a type/field
  defp current_key(%{tab: "types"} = state) do
    case TypesPanel.sel_path(state.model, %{sel: state.tsel}) do
      nil -> nil
      path -> {:type, path}
    end
  end

  defp current_key(%{sel_edge: i} = state) when i != nil do
    case Enum.at(state.model.edges, i) do
      {from, to, _} -> {:edge, from, to}
      nil -> nil
    end
  end

  defp current_key(%{selected: id} = state), do: if(state.model.nodes[id], do: {:node, id})

  defp xsel_ops(%{xml: nil}, _scroll?), do: []

  defp xsel_ops(state, scroll?) do
    {from, to} = ((key = current_key(state)) && XmlView.range(state.xml, key)) || {0, 0}
    [["xsel", "#xcode", from, to, scroll?]]
  end

  # The one place where selection and the document meet. Whatever changed the selection (a click on the diagram,
  # the Data types tree, the code itself, Undo, an import) is seen here by comparing before and after, so the code
  # highlight follows without anything being sent back, which is why the two can never chase each other. Only a
  # selection that came from somewhere other than the code scrolls it.
  defp sync_xml(_old, %{xopen: false} = new, _msg), do: new

  defp sync_xml(old, new, msg) do
    new = if old.model != new.model, do: schedule_xml(new), else: new
    scroll? = msg["t"] != "xclick"

    cond do
      current_key(old) == current_key(new) and old.tab == new.tab -> new
      # the ranges are about to change: highlight once the new document is shown
      new.xdirty -> %{new | xscroll: scroll?}
      true -> tap(new, &patch(xsel_ops(&1, scroll?)))
    end
  end

  # rebuilding takes longer the bigger the model, so the wait grows with it
  defp schedule_xml(%{xtimer: nil} = state),
    do: %{state | xdirty: true, xtimer: Process.send_after(self(), :xml_refresh, max(120, state.xms * 3))}

  defp schedule_xml(state), do: %{state | xdirty: true}

  defp select_key(state, {:node, id}) do
    if state.model.nodes[id] do
      state = if state.tab == "editor", do: state, else: render_all(%{state | tab: "editor"}, true)
      state |> select({:node, id}) |> reveal_node(id)
    else
      state
    end
  end

  defp select_key(state, {:edge, from, to}) do
    case Enum.find_index(state.model.edges, &match?({^from, ^to, _}, &1)) do
      nil ->
        state

      i ->
        state = if state.tab == "editor", do: state, else: render_all(%{state | tab: "editor"}, true)
        select(state, {:edge, i})
    end
  end

  defp select_key(state, {:type, path}) do
    if Types.fetch(state.model.types, path) do
      state = if state.tab == "types", do: state, else: render_all(%{state | tab: "types"}, true)
      select_type(state, TypesPanel.path_str(path))
    else
      state
    end
  end

  # bring the node into view when the selection came from outside the canvas
  defp reveal_node(state, id) do
    n = state.model.nodes[id]
    {x, y, w, h} = v = current_view(state)

    if n.x >= x and n.y >= y and n.x + n.w <= x + w and n.y + n.h <= y + h do
      state
    else
      {vx, vy} = View.center(v)
      set_view(state, View.pan(v, n.x + n.w / 2 - vx, n.y + n.h / 2 - vy), true)
    end
  end

  @dismiss ~s|<button class="dismiss" data-click="dismiss-report" title="Dismiss" aria-label="Dismiss">✕</button>|

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

  # a short message in a toast over the canvas; it hides itself after a few seconds
  defp say(state, msg, kind \\ :info) do
    n = state.toast + 1
    patch([["html", "#toast", Fmt.esc(msg)], ["attr", "#toast", "class", "toast #{kind}"], ["hidden", "#toast", false]])
    Process.send_after(self(), {:clear_toast, n}, 4000)
    %{state | toast: n}
  end

  defp render_all(state, return_state? \\ false) do
    state = if map_size(state.model.nodes) > 0, do: %{state | hint: true}, else: state
    {us, results} = :timer.tc(fn -> Eval.run(state.model) end)
    selected = if state.model.nodes[state.selected], do: state.selected, else: nil
    state = %{state | selected: selected, group: nil}

    patch(
      [
        ["attr", "#drd", "viewBox", viewbox(state)],
        ["html", "#scene", Svg.scene(state.model, results, state.selected, state.sel_edge)],
        ["html", "#panel", Panel.render(state.model, state.selected, results, state.dock)],
        ["html", "#types", TypesPanel.render(state.model, tui(state))],
        ["hidden", "#empty", map_size(state.model.nodes) > 0 or not state.hint],
        ["hidden", "#view-editor", state.tab != "editor"],
        ["hidden", "#view-types", state.tab != "types"],
        ["attr", "[data-click='tab:editor']", "aria-pressed", to_string(state.tab == "editor")],
        ["attr", "[data-click='tab:types']", "aria-pressed", to_string(state.tab == "types")],
        ["html", "#report", report_html(state.report)]
      ] ++ refresh_ops(state, results, us)
    )

    if return_state?, do: state, else: :ok
  end

  defp patch(ops), do: JS.run!(@patch_js, %{ops: ops})
end
