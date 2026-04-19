export function set_timeout(callback, delay_ms) {
  setTimeout(callback, delay_ms);
}

export function scroll_to_bottom(id) {
  requestAnimationFrame(() => {
    const el = document.getElementById(id);
    if (el) el.scrollTop = el.scrollHeight;
  });
}
