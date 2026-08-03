// Cove support site — vanilla JS, no dependencies.

const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ---------- nav condenses once you've scrolled past the hero ---------- */

(function navCondense() {
  const nav = document.querySelector('.nav');
  if (!nav) return;
  const onScroll = () => {
    nav.classList.toggle('is-condensed', window.scrollY > 40);
  };
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });
})();

/* ---------- reveal + tide-line: re-trigger on every enter AND exit,
   in either scroll direction, so a section actually leaves when it's
   no longer in focus instead of only ever animating in once. ---------- */

(function scrollReveal() {
  const targets = document.querySelectorAll('.reveal, .tide');
  if (!targets.length) return;

  // Elements marked [data-stagger] (gallery cards, changelog entries)
  // get a small transition-delay so they cascade in slightly rather
  // than all animating in lockstep.
  targets.forEach((el) => {
    if (el.dataset.stagger !== undefined) {
      el.style.transitionDelay = `${Number(el.dataset.stagger) * 90}ms`;
    }
  });

  if (prefersReducedMotion) {
    targets.forEach((el) => el.classList.add('is-visible', 'is-drawn'));
    return;
  }

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const el = entry.target;
        const shownClass = el.classList.contains('tide') ? 'is-drawn' : 'is-visible';
        el.classList.toggle(shownClass, entry.isIntersecting);
      }
    },
    { threshold: 0.18, rootMargin: '-8% 0px -8% 0px' }
  );

  targets.forEach((el) => observer.observe(el));
})();

/* ---------- Quick Add hero demo ----------
   Types out a handful of real Quick Add lines, then resolves each into
   the same shape of parsed row the app itself would show, and loops. */

(function quickAddDemo() {
  const inputEl = document.getElementById('demo-input');
  const resultEl = document.getElementById('demo-result');
  if (!inputEl || !resultEl) return;

  const examples = [
    {
      line: 'lab report @school !high fri 5pm',
      title: 'Lab report',
      meta: 'SCHOOL · HIGH · FRI 17:00',
      color: 'var(--area-school)',
    },
    {
      line: 'team sync @work tue 10am-11am',
      title: 'Team sync',
      meta: 'WORK · TUE 10:00–11:00',
      color: 'var(--area-work)',
    },
    {
      line: 'water plants',
      title: 'Water plants',
      meta: 'DUE TODAY',
      color: 'var(--ink-fainter)',
    },
  ];

  if (prefersReducedMotion) {
    const first = examples[0];
    inputEl.textContent = first.line;
    renderResult(first);
    resultEl.classList.add('is-shown');
    return;
  }

  const TYPE_MS = 45;
  const HOLD_MS = 1600;
  const ERASE_MS = 22;
  const GAP_MS = 500;

  let i = 0;
  let cancelled = false;

  function renderResult(example) {
    resultEl.innerHTML = `
      <span class="demo__bar-accent" style="background:${example.color}"></span>
      <div>
        <div class="demo__result-title">${example.title}</div>
        <div class="demo__result-meta">${example.meta}</div>
      </div>
    `;
  }

  function wait(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function typeText(text) {
    for (let c = 1; c <= text.length; c++) {
      if (cancelled) return;
      inputEl.textContent = text.slice(0, c);
      await wait(TYPE_MS);
    }
  }

  async function eraseText() {
    const text = inputEl.textContent;
    for (let c = text.length; c >= 0; c--) {
      if (cancelled) return;
      inputEl.textContent = text.slice(0, c);
      await wait(ERASE_MS);
    }
  }

  async function loop() {
    while (!cancelled) {
      const example = examples[i % examples.length];
      resultEl.classList.remove('is-shown');
      await typeText(example.line);
      await wait(250);
      renderResult(example);
      resultEl.classList.add('is-shown');
      await wait(HOLD_MS);
      resultEl.classList.remove('is-shown');
      await wait(200);
      await eraseText();
      await wait(GAP_MS);
      i++;
    }
  }

  // Pause the demo entirely while it's scrolled out of view — it's a
  // hero moment, not something that should keep ticking in the
  // background forever.
  const heroObserver = new IntersectionObserver(
    (entries) => {
      const visible = entries[0].isIntersecting;
      cancelled = !visible;
      if (visible) loop();
    },
    { threshold: 0.2 }
  );
  heroObserver.observe(document.querySelector('.demo'));
})();

/* ---------- feature showcase: preview swaps to match whichever
   labeled item sits closest to a reading line in the viewport, as the
   page scrolls past it in either direction — ordinary page scroll,
   not a separately-scrollable box, and not a click-to-switch tab bar. ---------- */

(function featureShowcase() {
  const items = [...document.querySelectorAll('.showcase__item[data-panel]')];
  const panels = [...document.querySelectorAll('.showcase__panel[data-panel]')];
  if (!items.length || !panels.length) return;

  function activate(name) {
    items.forEach((el) => el.classList.toggle('is-active', el.dataset.panel === name));
    panels.forEach((el) => el.classList.toggle('is-active', el.dataset.panel === name));
  }

  if (prefersReducedMotion) return; // first item stays active, no scroll-linked swapping

  // Whichever item's own vertical center sits closest to a reading
  // line in the viewport becomes active — a closest-match calculation
  // against ordinary page scroll, so every item passes the line
  // exactly once as you scroll through the section; there's no
  // artificial scroll-range ceiling the way a bounded sub-box has.
  let ticking = false;
  function updateActive() {
    ticking = false;
    const readingLine = window.innerHeight * 0.4;
    let closest = items[0];
    let closestDist = Infinity;
    for (const item of items) {
      const r = item.getBoundingClientRect();
      const dist = Math.abs(r.top + r.height / 2 - readingLine);
      if (dist < closestDist) {
        closestDist = dist;
        closest = item;
      }
    }
    activate(closest.dataset.panel);
  }
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(updateActive);
  }

  updateActive();
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll, { passive: true });
})();

/* ---------- accent theme swatches (§17 rewards) ----------
   A real preview of the cosmetic-unlock system: picking a theme
   actually re-themes this page's own accent color, live. */

(function themeSwatches() {
  // The reward card is duplicated (mobile inline-mock + desktop panel),
  // so "active" is scoped to buttons within the same swatch group, not
  // toggled globally across both copies.
  const groups = [...document.querySelectorAll('.reward-card__swatches')];
  if (!groups.length) return;

  groups.forEach((group) => {
    const buttons = [...group.querySelectorAll('.swatch[data-accent]')];
    buttons.forEach((btn) => {
      btn.addEventListener('click', () => {
        buttons.forEach((b) => b.classList.toggle('is-active', b === btn));
        document.documentElement.style.setProperty('--accent', btn.dataset.accent);
        document.documentElement.style.setProperty('--accent-dark', btn.dataset.accentDark);
      });
    });
  });
})();
