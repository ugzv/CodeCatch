// The hero plays what the app does: a code arrives, the banner slides in with the code
// already copied, ⌘V pastes it into the page. Then a code by email, then a sign-in link. With reduced motion it shows the end state, still.
(() => {
  const $ = (id) => document.getElementById(id);
  const banner = $("banner"), code = $("banner-code"), left = $("banner-left"), menubar = $("menubar-code");
  const copy = $("banner-copy"), keys = $("keys"), field = $("otp"), typed = $("otp-text");
  const ring = banner.querySelector(".ring"), linkBanner = $("banner-link");
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const grouped = (digits) => digits.slice(0, 3) + " " + digits.slice(3);
  let timers = [], digits = "482913", seconds = 598;

  // With reduced motion every step runs at once, so a scene shows its end state, still.
  const after = (ms, run) => still ? run() : timers.push(setTimeout(run, ms));
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

  // Every scene sets the sign-in page it happens on; the code scenes also set who sent
  // the code. The text scene's values are the ones in the HTML.
  const page = $("stage").querySelector(".window"), tile = banner.querySelector(".tile");
  const read = (el) => el.tagName === "IMG" ? el.getAttribute("src") : el.textContent;
  const texted = { ...Object.fromEntries([...$("stage").querySelectorAll("[data-fill]")].map((el) => [el.dataset.fill, read(el)])), brand: "google" };
  const emailed = {
    brand: "notion", icon: "/assets/services/notion.png", tab: "Log in – Notion", url: "notion.so/login",
    title: "Log in", note: "We sent a login code to y•••@gmail.com. Check your inbox.", prefix: "", button: "Continue",
    via: "/assets/services/gmail.png", who: "Notion", from: "",  // the Gmail badge already names the inbox
  };
  const linked = {
    brand: "slack", icon: "/assets/services/slack.png", tab: "Check your email – Slack", url: "slack.com/signin",
    title: "Check your email", note: "We sent a sign-in link to you@work.com. It expires in 30 minutes.", prefix: "", button: "Open Mail",
  };
  const fill = (root, values) => {
    for (const el of root.querySelectorAll("[data-fill]")) el.tagName === "IMG" ? el.src = values[el.dataset.fill] : el.textContent = values[el.dataset.fill];
  };
  const setPage = (values) => {
    fill(page, values);
    page.dataset.brand = values.brand;
    typed.textContent = "";
    field.classList.remove("on");
  };
  const codeScene = (values) => ({ length: 5500, run() {
    setPage(values);
    after(350, () => {  // once the last banner has faded out
      fill(banner, values);
      tile.classList.toggle("bleed", values !== texted);
      digits = String(Math.floor(100000 + Math.random() * 900000));
      seconds = 599;
      tick();
      code.textContent = grouped(digits);
      setCopied(false);
    });
    after(550, () => { banner.classList.add("on"); menubar.textContent = grouped(digits); });
    after(1100, () => setCopied(true));  // auto-copy: on the clipboard as the banner lands
    after(1900, () => keys.classList.add("on"));
    after(2300, paste);
    after(3300, () => keys.classList.remove("on"));
  } });

  // Each scene runs alone and the next starts when its time is up;
  // hovering a chip stops that clock and holds its scene on screen.
  const chips = [...$("types").children];
  const scenes = [
    codeScene(texted),
    codeScene(emailed),
    { length: 4800, run() { setPage(linked); after(550, () => linkBanner.classList.add("on")); } },
  ];
  let current = 0, next, due, remaining;

  const wait = (ms) => {
    clearTimeout(next);
    if (still) return;
    due = Date.now() + ms;
    next = setTimeout(() => show((current + 1) % scenes.length), ms);
  };
  function stop() {
    timers.forEach(clearTimeout);
    timers = [];
    clearTimeout(next);
  }
  function show(index) {
    stop();
    current = index;
    banner.classList.remove("on");
    linkBanner.classList.remove("on");
    keys.classList.remove("on");
    menubar.textContent = "";
    chips.forEach((chip, i) => chip.classList.toggle("on", i === index));
    scenes[index].run();
    wait(scenes[index].length);
  }
  chips.forEach((chip, i) => {
    chip.addEventListener("mouseenter", () => { if (i !== current) show(i); clearTimeout(next); remaining = due - Date.now(); });
    chip.addEventListener("mouseleave", () => wait(remaining));
    chip.addEventListener("click", () => show(i));
  });

  if (still) show(0);
  else {
    setInterval(tick, 1000);
    // Only while the stage is on screen: no timers running behind the fold.
    new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) show(0); else stop();
    }, { threshold: 0.35 }).observe($("stage"));
  }
  // The popover's search really filters its rows, as in the app.
  const rows = [...$("rows").children], count = $("count"), empty = $("empty");
  $("search").addEventListener("input", (event) => {
    const query = event.target.value.trim().toLowerCase();
    let shown = 0, links = 0;
    for (const row of rows) {
      const match = row.dataset.name.includes(query);
      row.hidden = !match;
      shown += match;
      links += match && !row.querySelector(".row-code");
    }
    // As the app counts: "items" once a link is among them, else "codes".
    const noun = links ? "item" : "code";
    count.textContent = shown + " " + noun + (shown === 1 ? "" : "s");
    empty.hidden = shown > 0;
  });

  // A click plays the app's copy: the pill says "Copied" for a moment, then shows the code again.
  let flash, restore = () => {};
  for (const row of rows) {
    const label = row.querySelector(".row-code > span");
    if (!label) continue;
    const digits = label.textContent;
    row.addEventListener("click", () => {
      clearTimeout(flash);
      restore();
      rows.forEach((other) => other.classList.remove("copied"));
      void row.offsetWidth;  // restart the checkmark's draw-on
      row.classList.add("copied");
      label.textContent = "Copied";
      restore = () => { label.textContent = digits; };
      flash = setTimeout(restore, 1200);
    });
  }

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
