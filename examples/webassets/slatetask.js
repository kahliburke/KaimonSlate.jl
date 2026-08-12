// slateTask — a request/response-with-progress effect as a signal-driven state machine, so a web cell
// never hand-rolls the idle→loading→done→error transitions or the supersede logic. The token /
// correlation is gone: `slateCall(channel, args, onProgress)` handles it framework-side, so this is
// just a tiny state wrapper.
//
//   const { slateTask } = await import(location.pathname + "/asset/webassets/slatetask.js");
//   const t = slateTask("my_channel");
//   await t.run({ ...args });                 // → live progress, then the result
//   t.state.value  →  { status, progress, result, error }
//
// Julia side is a plain 2-arg handler — no helper needed:
//   slate_on("my_channel", (args, progress) -> begin
//       for i in 1:n; progress((working = i, of = n)); …; end
//       result
//   end)
import { signal } from "@preact/signals";

export function slateTask(channel) {
  const state = signal({ status: "idle", progress: null, result: null, error: null });
  let seq = 0;   // a newer run() supersedes an older in-flight one — late progress/result is ignored

  async function run(args) {
    const mine = ++seq;
    state.value = { status: "loading", progress: null, result: null, error: null };
    try {
      const result = await window.slateCall(channel, args, (p) => {
        if (mine === seq) state.value = { ...state.value, progress: p };
      });
      if (mine === seq) state.value = { ...state.value, status: "done", result };
    } catch (error) {
      if (mine === seq) state.value = { ...state.value, status: "error", error: String(error) };
    }
    return state.value;
  }

  return { state, run };
}
