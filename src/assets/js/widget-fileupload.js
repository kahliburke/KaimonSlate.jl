// ── FileUpload: the reader supplies the data ─────────────────────────────────────────────────────
//
// Built into Slate, but implemented through the SAME `slateRegisterWidget` seam a third-party
// widget uses — the built-in `controlMarkup` chain in view.js is for kinds whose whole UI is one
// <input>, and this one has a drop target, a progress bar and a failure state. Going through the
// public seam keeps view.js from growing a special case, and means the extension point is exercised
// by something core depends on rather than only by examples.
//
// Every other control POSTs a JSON scalar to /api/<id>/bind/<cid>. This one sends BYTES to
// /api/<id>/upload-file, which stores the file under the notebook's datadir and then applies the
// bind server-side — so from the reactive graph's point of view nothing unusual happened.

(function () {
  const KB = 1024, MB = 1024 * 1024;
  const human = n => n < KB ? n + ' B' : n < MB ? (n / KB).toFixed(0) + ' KB' : (n / MB).toFixed(1) + ' MB';
  const esc = s => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  // What the control looks like in each of its three states. Kept as one function so the states
  // can't drift apart in layout — the reader should see the same control change, not three
  // different controls swapping places.
  function paint(el, state) {
    const p = el._params || {};
    const accept = p.accept ? ` accept="${esc(p.accept)}"` : '';
    if (state.busy) {
      el.innerHTML =
        `<span class="fuprog"><span class="fubar"><span class="fufill" style="width:${state.pct || 0}%"></span></span>
         <span class="fulabel">Uploading ${esc(state.name)}…</span></span>`;
      return;
    }
    const err = state.error
      ? `<span class="fuerr" title="${esc(state.error)}">${esc(state.error)}</span>` : '';
    const cur = state.file
      ? `<span class="fufile" title="${esc(state.file.path || '')}">📄 ${esc(state.file.name)}
           <span class="fusize">${human(state.file.size || 0)}</span></span>`
      : '';
    el.innerHTML =
      `<label class="fudrop${state.file ? ' has' : ''}${state.over ? ' over' : ''}">
         <input type="file"${accept} class="fuinput" hidden/>
         <span class="fucta">${state.file ? 'Replace…' : 'Choose a file'}</span>
         <span class="fuhint">${state.file ? '' : 'or drop it here'}</span>
       </label>${cur}${err}`;
  }

  window.slateRegisterWidget('fileupload', {
    wire(el, api) {
      el._params = api.params || {};
      // The bound value is the server's stored-file record (or null before anything is uploaded).
      const state = { file: api.value || null, busy: false, error: '', over: false, pct: 0 };
      const render = () => paint(el, state);

      async function upload(file) {
        if (!file) return;
        const max = el._params.maxbytes || 0;
        // A courtesy check only — the server enforces the real limit. Failing here saves the
        // reader from watching a 200 MB upload run to completion and then be refused.
        if (max && file.size > max) {
          state.error = `That file is ${human(file.size)}; this control accepts up to ${human(max)}.`;
          render(); return;
        }
        state.busy = true; state.error = ''; state.name = file.name; state.pct = 0; render();
        try {
          // XHR rather than fetch: upload PROGRESS is the whole reason. A reader who picked a
          // 40 MB file needs to see it moving, and fetch still can't report request progress.
          const body = await new Promise((resolve, reject) => {
            const x = new XMLHttpRequest();
            // `NB_ID` is core.js's top-level const — a global lexical binding, not a window
            // property, so it's referenced bare (as view.js and restore.js do).
            x.open('POST', '/api/' + NB_ID + '/upload-file');
            x.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
            // Header values must be latin-1; a filename routinely isn't (accents, CJK). Encode it
            // and let the server decode, rather than mangling the name the reader will look for.
            x.setRequestHeader('X-Slate-Filename', encodeURIComponent(file.name));
            x.setRequestHeader('X-Slate-Bind', api.name);
            x.setRequestHeader('X-Slate-Cell', api.bindId);
            x.upload.onprogress = e => {
              if (e.lengthComputable) { state.pct = Math.round(e.loaded / e.total * 100); render(); }
            };
            x.onload = () => x.status >= 200 && x.status < 300
              ? resolve(x.responseText)
              : reject(new Error(x.responseText || ('upload failed (' + x.status + ')')));
            x.onerror = () => reject(new Error('the connection dropped during the upload'));
            x.send(file);
          });
          // The route returns the notebook's new state (it applied the bind server-side), so the
          // page updates through exactly the path a slider change would have taken.
          state.busy = false;
          try { window.updateStates && window.updateStates(JSON.parse(body)); } catch (_) {}
        } catch (e) {
          state.busy = false;
          state.error = String(e && e.message ? e.message : e);
        }
        render();
      }

      el.addEventListener('change', e => {
        const inp = e.target.closest && e.target.closest('.fuinput');
        if (inp && inp.files && inp.files[0]) upload(inp.files[0]);
      });
      // Drag-and-drop is the natural gesture for "here is my data file", and the label is already
      // the drop target — so this only has to keep the hover affordance honest and take the file.
      el.addEventListener('dragover', e => {
        e.preventDefault(); e.stopPropagation();
        if (!state.over) { state.over = true; render(); }
      });
      el.addEventListener('dragleave', e => {
        e.preventDefault();
        if (state.over) { state.over = false; render(); }
      });
      el.addEventListener('drop', e => {
        e.preventDefault(); e.stopPropagation();
        state.over = false;
        const f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
        f ? upload(f) : render();
      });

      el._fuState = state;
      render();
    },

    // A reactive update (the notebook re-ran, or another tab uploaded). Never clobber a live
    // upload — the in-flight bytes are the newer truth.
    sync(el, value) {
      const s = el._fuState;
      if (!s || s.busy) return;
      s.file = value || null;
      paint(el, s);
    },
  });
})();
