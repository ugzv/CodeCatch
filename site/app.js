// The hero plays what the app does: a code arrives, the banner slides in with the code
// already copied, ⌘V pastes it into the page. With reduced motion it shows the end state, still.
(() => {
  const $ = (id) => document.getElementById(id);
  const banner = $("banner"), code = $("banner-code"), left = $("banner-left"), menubar = $("menubar-code");
  const copy = $("banner-copy"), keys = $("keys"), field = $("otp"), typed = $("otp-text");
  const ring = banner.querySelector(".ring");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const grouped = (digits) => digits.slice(0, 3) + " " + digits.slice(3);
  let timers = [], digits = "482913", seconds = 598;

  const after = (ms, run) => timers.push(setTimeout(run, ms));
  const setCopied = (on) => {
    copy.classList.toggle("copied", on);
    copy.querySelector("span").textContent = on ? "Copied" : "Copy";
    copy.querySelector("use").setAttribute("href", on ? "#i-check" : "#i-copy");
  };
  const paste = () => { typed.textContent = digits; field.classList.add("on"); };
  const tick = () => {
    seconds = Math.max(0, seconds - 1);
    left.textContent = Math.floor(seconds / 60) + ":" + String(seconds % 60).padStart(2, "0");
    ring.style.setProperty("--p", seconds / 600);
  };

  function play() {
    timers.forEach(clearTimeout);
    timers = [];
    digits = String(Math.floor(100000 + Math.random() * 900000));
    seconds = 599;
    tick();
    code.textContent = grouped(digits);
    typed.textContent = "";
    field.classList.remove("on");
    banner.classList.remove("on");
    keys.classList.remove("on");
    menubar.textContent = "";
    setCopied(false);
    after(900, () => { banner.classList.add("on"); menubar.textContent = grouped(digits); });
    after(1500, () => setCopied(true));  // auto-copy: on the clipboard as the banner lands
    after(2600, () => keys.classList.add("on"));
    after(3100, paste);
    after(4300, () => keys.classList.remove("on"));
    after(8200, () => banner.classList.remove("on"));
    after(9200, play);
  }

  if (still) {
    code.textContent = grouped(digits);
    menubar.textContent = grouped(digits);
    banner.classList.add("on");
    setCopied(true);
    paste();
  } else {
    setInterval(tick, 1000);
    // Only while the stage is on screen: no timers running behind the fold.
    new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) play(); else { timers.forEach(clearTimeout); timers = []; }
    }, { threshold: 0.35 }).observe($("stage"));
  }
  // The popover's search really filters its rows, as in the app.
  const rows = [...$("rows").children], count = $("count"), empty = $("empty");
  $("search").addEventListener("input", (event) => {
    const query = event.target.value.trim().toLowerCase();
    let shown = 0;
    for (const row of rows) {
      const match = row.dataset.name.includes(query);
      row.hidden = !match;
      shown += match;
    }
    count.textContent = shown === 1 ? "1 code" : shown + " codes";
    empty.hidden = shown > 0;
  });

  // The settings panel's switches work, as in the app.
  for (const control of document.querySelectorAll("button.switch")) {
    control.addEventListener("click", () => control.setAttribute("aria-checked", control.getAttribute("aria-checked") !== "true"));
  }

  // Sections ease in once.
  const targets = document.querySelectorAll(".feature, .steps li, .cta");
  if (still || !("IntersectionObserver" in window)) return;
  const reveal = new IntersectionObserver((entries) => {
    for (const entry of entries) if (entry.isIntersecting) { entry.target.classList.add("in"); reveal.unobserve(entry.target); }
  }, { threshold: 0.15 });
  targets.forEach((el) => { el.classList.add("reveal"); reveal.observe(el); });
})();
