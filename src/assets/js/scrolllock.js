// The page under a modal stays still: while any modal holds the lock the document does not scroll.
// Each holder names itself, so two stacked modals (a Prepare and its sysimage list) release it only
// when the last one closes.
const holders = new Set();
export function lockScroll(who, on) {
  on ? holders.add(who) : holders.delete(who);
  document.documentElement.classList.toggle('scroll-locked', holders.size > 0);
}
