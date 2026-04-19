export function set_timeout(callback, delay_ms) {
  setTimeout(callback, delay_ms);
}

export function fetch_json(url, callback) {
  fetch(url)
    .then(r => r.text())
    .then(text => callback(text))
    .catch(_err => callback("[]"));
}

export function scroll_to_bottom(id) {
  requestAnimationFrame(() => {
    const el = document.getElementById(id);
    if (el) el.scrollTop = el.scrollHeight;
  });
}
