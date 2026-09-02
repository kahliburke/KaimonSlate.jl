// Answering a cluster that will not take a key.
//
// Plenty of production clusters refuse public keys and want a password plus a second factor — a
// one-time code, or a push you accept on a phone. Slate cannot type either, so the ssh client asks
// a helper, the helper parks the prompt, and the hub pushes it here as `sshauth:{...}`.
//
// Whatever ssh asked is what gets shown. The dialog does not know the order or the number of
// prompts, and must not: one cluster wants password-then-code, another sends a push and says so,
// another offers Duo's numbered menu. Each arrives, is answered, and the next one comes.
(function () {
  'use strict';

  let el = null, current = null;

  function close() {
    if (el) { el.remove(); el = null; }
    current = null;
  }

  function send(body) {
    return fetch('/api/sshauth', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).catch(() => {});
  }

  function answer() {
    if (!current) return;
    const input = el.querySelector('.sshauth-input');
    const val = input ? input.value : '';
    const id = current.id;
    // Say what is happening rather than vanishing: on a 2FA cluster the NEXT prompt can take a few
    // seconds to arrive, and a dialog that disappears reads as "nothing happened".
    el.querySelector('.sshauth-body').innerHTML =
      '<div class="sshauth-wait"><span class="sshauth-spin"></span>working…</div>';
    current = null;
    send({ id: id, answer: val }).then(() => { setTimeout(() => { if (!current) close(); }, 400); });
  }

  function cancel() {
    if (current) send({ id: current.id, cancel: true });
    close();
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, c =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }

  // A prompt with nothing to type — "Duo push sent" and the like. ssh still wants a newline back,
  // so the dialog offers a button rather than a field: there is no answer, only an acknowledgement.
  function isNotice(p) {
    return /pushed|sent|approve|check your|waiting/i.test(p) && !/:\s*$/.test(p.replace(/\s+$/, ''));
  }

  // WHAT is being asked for, as a heading. ssh's own wording stays below it, but two prompts that
  // both read "(you@host) …:" and both mask their input are far too easy to answer with the other
  // one's answer — and on a one-time code, a wrong answer burns the code that would have worked.
  function kindOf(p) {
    if (/one-time|oath|otp|passcode|token|\bcode\b|verification/i.test(p))
      return { label: 'One-time code', icon: '🔢', hint: 'from your authenticator' };
    if (/passphrase/i.test(p)) return { label: 'Key passphrase', icon: '🔐', hint: '' };
    if (/password/i.test(p))   return { label: 'Password', icon: '🔑', hint: 'your account password' };
    if (/duo|push|approve/i.test(p)) return { label: 'Approve the push', icon: '📲', hint: 'on your phone' };
    return { label: 'Authentication', icon: '🔒', hint: '' };
  }

  function show(msg) {
    close();
    current = msg;
    const notice = isNotice(msg.prompt);
    const kind = kindOf(msg.prompt);
    el = document.createElement('div');
    el.className = 'sshauth-back';
    el.innerHTML =
      '<div class="sshauth" role="dialog" aria-modal="true">' +
        '<div class="sshauth-head">' +
          '<span class="sshauth-lock">' + kind.icon + '</span>' +
          '<span class="sshauth-kind">' + esc(kind.label) + '</span>' +
          '<span class="sshauth-sub">' + esc(msg.host) + '</span>' +
        '</div>' +
        '<div class="sshauth-body">' +
          (kind.hint ? '<div class="sshauth-hint">' + esc(kind.hint) + '</div>' : '') +
          (notice ? '' :
            '<input class="sshauth-input" type="' + (msg.secret ? 'password' : 'text') + '" ' +
                   'autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" />') +
          // ssh's own words, below the heading — not a paraphrase.
          '<div class="sshauth-prompt">' + esc(msg.prompt.trim()) + '</div>' +
        '</div>' +
        '<div class="sshauth-foot">' +
          '<span class="sshauth-note">Asked once per host.</span>' +
          '<button class="sshauth-cancel">Cancel</button>' +
          '<button class="sshauth-ok">' + (notice ? 'Continue' : 'Send') + '</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(el);

    el.querySelector('.sshauth-ok').onclick = answer;
    el.querySelector('.sshauth-cancel').onclick = cancel;
    el.addEventListener('keydown', e => {
      if (e.key === 'Enter') { e.preventDefault(); answer(); }
      else if (e.key === 'Escape') { e.preventDefault(); cancel(); }
    });
    const input = el.querySelector('.sshauth-input');
    (input || el.querySelector('.sshauth-ok')).focus();
  }

  window.onSshAuth = show;
  // The prompt is gone — answered elsewhere, cancelled, or timed out. Close the dialog rather than
  // leaving one on screen that nothing is waiting on.
  window.onSshAuthDone = function (id) { if (current && current.id === id) close(); };
})();
