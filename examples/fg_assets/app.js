const el = document.querySelector('.fg-count');
let n = 0;
if (el) setInterval(() => { el.textContent = String(++n); }, 1000);
