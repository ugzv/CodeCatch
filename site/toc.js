// The rail's list follows your reading, down and back up: the current section is the last
// heading above the top third of the window, and one bar slides along the line to it.
// Beside the article the list is always open; above it, on narrow screens, it starts closed.
(() => {
  const list = document.querySelector(".toc ol");
  if (!list) return;
  const details = list.closest("details");
  const links = [...list.querySelectorAll("a")];
  const heads = links.map((a) => document.getElementById(a.hash.slice(1)));
  let shown;
  const mark = () => {
    const current = Math.max(0, heads.findLastIndex((h) => h.getBoundingClientRect().top < innerHeight / 3));
    if (current === shown) return;
    shown = current;
    links.forEach((a, i) => i === current ? a.setAttribute("aria-current", "location") : a.removeAttribute("aria-current"));
    const link = links[current];
    list.style.setProperty("--y", link.offsetTop + "px");
    list.style.setProperty("--h", link.offsetHeight + "px");
  };
  const remark = () => { shown = -1; mark(); };  // after the list's layout changes

  const wide = matchMedia("(min-width: 1024px)");
  const fit = () => { details.open = wide.matches; };
  wide.addEventListener("change", fit);
  fit();
  // Closing before the jump lets the page scroll to where the heading lands without the list.
  list.addEventListener("click", (event) => { if (event.target.closest("a") && !wide.matches) details.open = false; });
  details.addEventListener("toggle", remark);

  addEventListener("scroll", mark, { passive: true });
  addEventListener("resize", remark);
  addEventListener("load", mark);
  mark();
})();
