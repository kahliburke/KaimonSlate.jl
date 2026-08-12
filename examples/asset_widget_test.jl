try; import KaimonSlate; catch; error("This is a Kaimon Slate notebook — running it as plain Julia needs the KaimonSlate runtime in this environment. Add it with `import Pkg; Pkg.add(\"KaimonSlate\")`, or open it in Kaimon Slate."); end; KaimonSlate.standalone!(@__MODULE__; dir=@__DIR__)

#%% md id=intro
@md"""
# 📦 `save_asset` — handing bulk data to the browser

Interpolating a large array into JS as JSON is wasteful and lossy. `save_asset(name, value)` instead
stores the value server-side and returns a handle; the front end fetches it with `Slate.asset(handle)`.

The encoding follows the value. A `NamedTuple` or `Dict` serializes to JSON. A numeric array goes over
as **packed binary in column-major order** and arrives as an ndarray-lite object — `{data, shape, order}`
plus an `at(i, j)` accessor — so a 200×200 `Float32` field costs 160 KB of buffer instead of megabytes
of decimal text. `Slate.assetInfo(handle)` reports dtype, shape and byte count without fetching.

Assets survive export: a saved asset is written alongside the exported page, so these widgets keep
working in a static HTML build.
"""

#%% md id=h_json
@md"""
## A JSON asset

A `NamedTuple` in, one `fetch` out.
"""

#%% code id=asset_demo
## A NamedTuple → JSON asset (serialized server-side), loaded by a widget.
data = save_asset("greeting.json", (msg = "hello from a saved asset", n = 42))

WebPage(
    html = "<div id=\"asset-out\" style=\"padding:14px;font-size:16px;color:#8fd6ff\">loading…</div>",
    js = """
    Slate.asset("$(data)").then(function(d){
      document.getElementById("asset-out").textContent = d.msg + "  (n=" + d.n + ")";
    });
    """
)

#%% md id=h_binary
@md"""
## A binary matrix asset

The `Float32` matrix goes straight to `save_asset` — no manual `reinterpret`. The canvas reads it
through `A.at(y, x)`, and because the slider is a dependency the field is re-saved and redrawn on
every move. Hover the canvas to read values back out of the buffer.
"""

#%% code id=72e183
@bind freq Slider(0.1:.1:2)

#%% code id=field_demo controls=freq
## A Float32 matrix passed STRAIGHT to save_asset → packed binary (col-major) → client ndarray.
n = 200
field = Float32[sin(i/8)*cos(j/6) + 0.3f0*freq*sin((i+j)/5) for i in 1:n, j in 1:n]
lo, hi = extrema(field)
fld = save_asset("field", (field .- lo) ./ (hi - lo))          # matrix in, no manual reinterpret

WebPage(
    html = """<div style="padding:10px">
      <canvas id="fld" style="width:320px;height:320px;image-rendering:pixelated;border:1px solid #333;border-radius:6px"></canvas>
      <div id="fld-read" style="margin-top:8px;color:#8fd6ff;font-size:13px;font-family:monospace">loading…</div>
      <div id="fld-info" style="margin-top:8px;color:#8fd6ff;font-size:13px;font-family:monospace"></div>
    </div>""",
    js = """
    var info = Slate.assetInfo("$(fld)");
    document.getElementById("fld-info").textContent = JSON.stringify(info);
    Slate.asset("$(fld)").then(function(A){
      var h = A.shape[0], w = A.shape[1];                       // col-major matrix: [rows, cols]
      var cv = document.getElementById("fld"); cv.width = w; cv.height = h;
      var ctx = cv.getContext("2d"), img = ctx.createImageData(w, h);
      for (var x=0; x<w; x++) for (var y=0; y<h; y++){
        var v = A.at(y, x), o = (y*w + x)*4;                    // ndarray-lite accessor
        img.data[o]=255*v; img.data[o+1]=255*(1-Math.abs(v-0.5)*2); img.data[o+2]=255*(1-v); img.data[o+3]=255;
      }
      ctx.putImageData(img, 0, 0);
      var base = info.dtype + " " + info.shape.join("×") + "  (" + info.bytes + " bytes · cell " + info.cell + ")";
      document.getElementById("fld-read").textContent = base;
      cv.onmousemove = function(e){
        var b = cv.getBoundingClientRect();
        var x = Math.floor((e.clientX-b.left)/b.width*w), y = Math.floor((e.clientY-b.top)/b.height*h);
        if(x>=0&&x<w&&y>=0&&y<h) document.getElementById("fld-read").textContent = base + "   field["+(y+1)+","+(x+1)+"] = "+A.at(y,x).toFixed(3);
      };
    });
    """
)

#%% md id=h_ndarray
@md"""
## The same buffer, read by a real npm `ndarray`

The ndarray-lite object is deliberately compatible with the npm `ndarray` package: wrap `A.data` with
column-major strides `[1, h]` and the whole JS array ecosystem applies to the bytes Julia sent, with
no copy. Here that's a column-mean reduction, charted with Observable Plot.
"""

#%% web id=ndarray_demo
@web(js"""
// Interpret the save_asset binary with the REAL npm `ndarray`, chart it with Observable Plot.
const [ndarray, Plot] = await Promise.all([
  import("https://esm.sh/ndarray@1.0.19").then(m => m.default),
  import("https://esm.sh/@observablehq/plot@0.6"),
]);

const A = await Slate.asset({{ fld }});                 // ndarray-lite: {data, shape:[h,w], order:'col'}
const [h, w] = A.shape;
const nd = ndarray(A.data, [h, w], [1, h]);            // wrap the SAME buffer, col-major strides

// A data reduction with the real ndarray API — column means across the field.
const colMean = Array.from({ length: w }, (_, j) => {
  let s = 0; for (let i = 0; i < h; i++) s += nd.get(i, j);
  return { col: j, mean: s / h };
});

const fig = Plot.plot({
  height: 290, width: 480, marginLeft: 44,
  x: { label: "column" }, y: { label: "mean", grid: true },
  marks: [ Plot.ruleY([0]), Plot.lineY(colMean, { x: "col", y: "mean", stroke: "#5aa9e6", strokeWidth: 2 }) ],
});
root.replaceChildren(
  Object.assign(document.createElement("div"),
    { style: "font:12px ui-monospace,monospace;color:#8fd6ff;margin-bottom:4px",
      textContent: `ndarray ${nd.dtype} ${h}×${w}  ·  nd.get(0,0)=${nd.get(0,0).toFixed(3)}` }),
  fig,
);
""")
