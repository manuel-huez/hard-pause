'use strict';

// Low Light artwork and motion. Catmull-Rom contour interpolation and snapshot
// retargeting follow Bloub's engine/shape design; see LICENSE.txt and NOTICE.txt.
(() => {
  const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
  const mix = (a, b, t) => a + (b - a) * t;
  const ease = (t) => {
    t = clamp(t);
    return t * t * (3 - 2 * t);
  };
  const round = (x) => Math.round(x * 100) / 100;
  const moods = {
    calm: { open: 0, smile: 4, gazeY: 0 },
    waiting: { open: 0, smile: 2, gazeY: 3 },
    resting: { open: 0.9, smile: 7, gazeY: -2 },
  };
  const blend = (a, b, t) =>
    Object.fromEntries(Object.keys(a).map((key) => [key, mix(a[key], b[key], t)]));
  // A broad cumulus outline stays recognisably cloud-shaped in every pose.
  const curves = [
    [79, 277, 44, 270, 38, 220, 68, 197],
    [68, 197, 47, 161, 73, 122, 108, 128],
    [108, 128, 118, 91, 166, 83, 192, 111],
    [192, 111, 224, 82, 269, 99, 276, 137],
    [276, 137, 310, 130, 339, 160, 323, 191],
    [323, 191, 359, 213, 350, 261, 321, 277],
    [321, 277, 313, 313, 270, 324, 244, 304],
    [244, 304, 219, 325, 182, 325, 164, 309],
    [164, 309, 122, 324, 84, 306, 79, 277],
  ];
  const outline = curves.flatMap((c) =>
    Array.from({ length: 10 }, (_, i) => {
      const t = i / 10,
        u = 1 - t;
      return [
        u * u * u * c[0] + 3 * u * u * t * c[2] + 3 * u * t * t * c[4] + t * t * t * c[6],
        u * u * u * c[1] + 3 * u * u * t * c[3] + 3 * u * t * t * c[5] + t * t * t * c[7],
      ];
    }),
  );
  function closedPath(points) {
    let d = `M${points[0].map(round).join(' ')}`;
    for (let i = 0; i < points.length; i++) {
      const a = points[(i + points.length - 1) % points.length],
        b = points[i];
      const c = points[(i + 1) % points.length],
        e = points[(i + 2) % points.length];
      d += `C${round(b[0] + (c[0] - a[0]) / 6)} ${round(b[1] + (c[1] - a[1]) / 6)} ${round(c[0] - (e[0] - b[0]) / 6)} ${round(c[1] - (e[1] - b[1]) / 6)} ${round(c[0])} ${round(c[1])}`;
    }
    return `${d}Z`;
  }
  // Seeded schedule and fast-close/soft-open lids adapted from Bloub face.ts.
  const blinkStarts = [];
  let seed = 0x5eed;
  const random = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return seed / 4294967296;
  };
  for (let time = 2.3; time < 900;) {
    blinkStarts.push(time);
    time += 1.9 + random() * 2.7;
    if (random() < 0.18) {
      blinkStarts.push(time);
      time += 0.25;
    }
  }
  function blinkLid(time) {
    const t = ((time % 900) + 900) % 900;
    for (const start of blinkStarts) {
      if (start > t) break;
      const age = t - start;
      if (age < 0.21) return age < 0.075 ? 1 - ease(age / 0.075) : ease((age - 0.075) / 0.135);
    }
    return 1;
  }
  class Engine {
    constructor(mood = 'calm') {
      this.from = this.to = moods[mood] || moods.calm;
      this.changed = -10;

      this.lookFrom = this.lookTo = { x: 0, y: 0 };
      this.lookChanged = -10;
      this.helloAt = -10;
      this.attentionFrom = this.attentionTo = 0;
      this.attentionChanged = -10;
      this.eyeFrom = this.eyeReducedFrom = { shape: this.to.open, lid: 1 };
      this.eyeTarget = this.to.open;
      this.eyeChanged = -10;
      this.eyeDuration = 0.9;
      this.eyeMode = 'settle';
    }
    pose(t) {
      return blend(this.from, this.to, ease((t - this.changed) / 1.5));
    }
    setMood(mood, t) {
      if (!moods[mood] || this.to === moods[mood]) return;
      this.from = this.pose(t);
      this.to = moods[mood];
      this.changed = t;
      if (!this.attentionTo)
        this.retargetEyes(this.to.open, t, this.to.open < 0.4 ? 'sleep' : 'settle');
    }

    look(t) {
      // Fast initial response avoids restarting from zero speed while typing.
      const progress = 1 - (1 - clamp((t - this.lookChanged) / 0.2)) ** 5;
      return blend(this.lookFrom, this.lookTo, progress);
    }
    setLook(x, y, t) {
      const target = { x: clamp(x, -1, 1) * 16, y: clamp(y, -1, 1) * 10 };
      if (target.x === this.lookTo.x && target.y === this.lookTo.y) return;
      this.lookFrom = this.look(t);
      this.lookTo = target;
      this.lookChanged = t;
    }
    attention(t) {
      const elapsed = t - this.attentionChanged;
      // Ease smile and gaze drift separately from the three-stage eye shape sequence.
      const progress = this.attentionTo ? elapsed / 0.9 : (elapsed - 0.24) / 1.4;
      return mix(this.attentionFrom, this.attentionTo, ease(progress));
    }
    // Full shape poses, not eyelid compression: long sleepy curve -> upright oval.
    eyePose(t, reduced = false) {
      const age = t - this.eyeChanged;
      const from = reduced ? this.eyeReducedFrom : this.eyeFrom;
      const end = { shape: this.eyeTarget, lid: 1 };
      const sleep = (start, elapsed) => {
        if (reduced) return blend(start, end, ease(elapsed / 1.4));
        const shut = { shape: 0, lid: 1 };
        const reopened = { shape: start.shape * 0.55, lid: 1 };
        if (elapsed < 0.12) return blend(start, shut, ease(elapsed / 0.12));
        if (elapsed < 0.26) return blend(shut, reopened, ease((elapsed - 0.12) / 0.14));
        return blend(reopened, end, ease((elapsed - 0.26) / 1.4));
      };
      let pose, duration;
      if (this.eyeMode === 'greet') {
        duration = reduced ? 2.85 : 3.11;
        pose =
          age < 0.45
            ? blend(from, { shape: 1, lid: 1 }, ease(age / 0.45))
            : age < 1.45
              ? { shape: 1, lid: 1 }
              : sleep({ shape: 1, lid: 1 }, age - 1.45);
      } else if (this.eyeMode === 'sleep') {
        duration = reduced ? 1.4 : 1.66;
        pose = sleep(from, age);
      } else {
        duration = this.eyeDuration;
        pose = blend(from, end, ease(age / duration));
      }
      // Natural blinks remain separate and run only after an expression settles.
      return { ...pose, lid: reduced ? 1 : pose.lid * (age >= duration ? blinkLid(t) : 1) };
    }
    retargetEyes(target, t, mode = 'settle', duration = 0.9) {
      this.eyeFrom = this.eyePose(t);
      this.eyeReducedFrom = this.eyePose(t, true);
      this.eyeTarget = target;
      this.eyeChanged = t;
      this.eyeDuration = duration;
      this.eyeMode = mode === 'sleep' && this.eyeFrom.shape <= target ? 'settle' : mode;
    }
    greeting(t) {
      const age = t - this.helloAt;
      if (age < 0 || age >= 3.11) return 0;
      return age < 0.45 ? ease(age / 0.45) : 1 - ease((age - 1.71) / 1.4);
    }
    setAttention(active, t) {
      const target = active ? 1 : 0;
      if (target === this.attentionTo) return;
      this.retargetEyes(
        active ? 1 : this.to.open,
        t,
        active || this.to.open >= 0.4 ? 'settle' : 'sleep',
      );
      this.attentionFrom = this.attention(t);
      this.attentionTo = target;
      this.attentionChanged = t;
    }
    greet(t) {
      if (t - this.helloAt <= 3.11) return;
      this.retargetEyes(
        this.attentionTo ? 1 : this.to.open,
        t,
        this.attentionTo || this.to.open >= 0.4 ? 'settle' : 'greet',
        0.45,
      );
      this.helloAt = t;
    }
    sample(t, reduced = false) {
      const p = this.pose(t),
        look = this.look(t);
      const hello = this.greeting(t);
      const attention = this.attention(t);
      const awake = Math.max(hello, attention);
      const time = reduced ? 0 : t;
      const roll = reduced ? 0 : 0.026 * Math.sin(time * 0.43);
      // Small travelling ripples soften the sides without losing the cloud's lobes.
      const breath = reduced ? 1 : 1 + 0.004 * Math.sin(time * 0.72);
      function flow(x, y) {
        const nx = (x - 200) / 165,
          ny = (y - 205) / 110;
        const side = Math.min(1, Math.abs(nx)) * 0.8 + 0.2;
        const dx = reduced ? 0 : 2.8 * Math.sin(time * 0.78 - ny * 2.4 + nx) * side;
        const dy = reduced ? 0 : 1.8 * Math.sin(time * 0.62 + nx * 2.8 - ny) * side;
        const xx = (x - 200) * breath + dx,
          yy = (y - 220) * breath + dy;
        return [
          200 + xx * Math.cos(roll) - yy * Math.sin(roll),
          220 +
            xx * Math.sin(roll) +
            yy * Math.cos(roll) +
            (reduced ? 0 : 3 * Math.sin(time * 0.59)),
        ];
      }
      const path = closedPath(outline.map(([x, y]) => flow(x, y)));
      const face = flow(199, 221);
      const eyePose = this.eyePose(t, reduced);
      const blink = eyePose.lid;
      const expressionOpen = eyePose.shape;
      const open = expressionOpen * blink;
      const wander = 1 - attention;
      const yaw = look.x / 65 + (reduced ? 0 : 0.055 * Math.sin(time * 0.41) * wander);
      const pitch = look.y / 90;
      // Every facial control point uses this same sphere projection, including
      // the mouth. Near/far foreshortening is a result of depth, not a second gaze.
      const project = (x, y) => {
        const radius = 150;
        const z = Math.sqrt(Math.max(1, radius * radius - x * x - y * y));
        return [
          x * Math.cos(yaw) + (z - radius) * Math.sin(yaw),
          y * Math.cos(pitch) + (z - radius) * Math.sin(pitch),
        ];
      };
      const point = (x, y) => project(x, y).map(round).join(' ');
      const eyes = [-43, 44].map((x, i) => {
        const y = i === 0 ? -10 : -7;
        const w = mix(16, 4.1, expressionOpen);
        const h = mix(0, 7.1, expressionOpen) * blink;
        const curve = 8 * (1 - expressionOpen);
        const tilt = (i === 0 ? -1 : 1) * 0.035 * expressionOpen;
        const ep = (dx, dy) =>
          point(
            x + dx * Math.cos(tilt) - dy * Math.sin(tilt),
            y + dx * Math.sin(tilt) + dy * Math.cos(tilt),
          );
        return `M${ep(-w, 0)}C${ep(-w, curve - h * 1.34)} ${ep(w, curve - h * 1.34)} ${ep(w, 0)}C${ep(w, curve + h * 1.34)} ${ep(-w, curve + h * 1.34)} ${ep(-w, 0)}Z`;
      });
      const fx = face[0] + look.x + (reduced ? 0 : 2 * Math.sin(time * 0.37) * wander);
      const fy = face[1] + p.gazeY + look.y;
      const smile = mix(p.smile, 8, awake);
      const mouth = `M${point(-7, 20)}C${point(-1, 20 + smile)} ${point(7, 20 + smile)} ${point(12, 20)}`;
      const light = flow(152, 143);
      return {
        path,
        eyes,
        mouth,
        face: `translate(${round(fx)} ${round(fy)}) rotate(${round(((roll * 180) / Math.PI) * 0.7)}) scale(.82)`,
        light,
        moon: `translate(0 ${round(reduced ? 0 : 2 * Math.sin(time * 0.59))})`,
        roll,
        open,
        blink,
        eyeGeometry: {
          width: mix(16, 4.1, expressionOpen),
          height: 7.1 * open,
          curve: 8 * (1 - expressionOpen),
          shape: expressionOpen,
        },
        pose: p,
      };
    }
  }
  let serial = 0;
  function mount(element, options = {}) {
    const doc = element.ownerDocument,
      win = doc.defaultView;
    const id = `low-light-${++serial}`;
    const previousId = element.querySelector('img')?.id;
    element.innerHTML = `<svg class="low-light-svg" viewBox="0 0 400 380" aria-hidden="true" focusable="false"><defs><radialGradient id="${id}-body" gradientUnits="userSpaceOnUse" cx="166" cy="120" r="225"><stop stop-color="#c6d5e9"/><stop offset=".55" stop-color="#94aaca"/><stop offset="1" stop-color="#637a9b"/></radialGradient><radialGradient id="${id}-halo"><stop stop-color="#8daeda" stop-opacity=".16"/><stop offset="1" stop-color="#8daeda" stop-opacity="0"/></radialGradient><linearGradient id="${id}-moon" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#fff4d3"/><stop offset="1" stop-color="#d2bf91"/></linearGradient><radialGradient id="${id}-shade"><stop stop-color="#233854" stop-opacity=".24"/><stop offset="1" stop-color="#233854" stop-opacity="0"/></radialGradient><clipPath id="${id}-clip"><path class="low-light-outline"/></clipPath><filter id="${id}-velvet" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency=".72" numOctaves="3" seed="12"/><feColorMatrix type="saturate" values="0"/></filter></defs><ellipse cx="200" cy="210" rx="197" ry="169" fill="url(#${id}-halo)"/><path class="low-light-moon" d="M326 67C301 68 282 90 282 115C282 148 312 170 343 158C317 158 298 139 300 115C301 94 312 78 326 67Z" fill="url(#${id}-moon)"/><path class="low-light-body" fill="url(#${id}-body)" stroke="#d1e1f4" stroke-opacity=".12" stroke-width="1"/><g clip-path="url(#${id}-clip)"><g class="low-light-plush"><ellipse cx="215" cy="318" rx="168" ry="91" fill="url(#${id}-shade)"/></g><rect x="20" y="90" width="360" height="220" filter="url(#${id}-velvet)" opacity=".07" class="low-light-texture"/></g><g class="low-light-face"><path class="low-light-eye"/><path class="low-light-eye"/><path class="low-light-mouth"/></g></svg>`;
    const svg = element.querySelector('svg'),
      body = svg.querySelector('.low-light-body');
    if (previousId) svg.id = previousId;
    const face = svg.querySelector('.low-light-face'),
      eyes = svg.querySelectorAll('.low-light-eye');
    const mouth = svg.querySelector('.low-light-mouth'),
      moon = svg.querySelector('.low-light-moon');
    const gradient = svg.querySelector('radialGradient');
    const engine = new Engine(options.mood);
    const media = win.matchMedia('(prefers-reduced-motion: reduce)');
    let reduced = media.matches,
      active = true,
      visible = true,
      destroyed = false;
    let raf = 0,
      clock = 0,
      last = null,
      rendered = -1,
      settlingUntil = 0;
    function draw() {
      const f = engine.sample(clock, reduced);
      body.setAttribute('d', f.path);
      svg.querySelector('.low-light-outline').setAttribute('d', f.path);
      face.setAttribute('transform', f.face);
      eyes.forEach((eye, i) => eye.setAttribute('d', f.eyes[i]));
      mouth.setAttribute('d', f.mouth);
      moon.setAttribute('transform', f.moon);
      gradient.setAttribute('cx', round(f.light[0]));
      gradient.setAttribute('cy', round(f.light[1]));
    }
    function canRun() {
      return !destroyed && active && visible && !doc.hidden && (!reduced || clock < settlingUntil);
    }
    function tick(stamp) {
      raf = 0;
      if (!canRun()) {
        last = null;
        return;
      }
      if (last !== null) clock += Math.min((stamp - last) / 1000, 0.05);
      last = stamp;
      // 30 updates per second; animation clock still uses the actual timestamp.
      if (stamp - rendered >= 30) {
        draw();
        rendered = stamp;
      }
      raf = win.requestAnimationFrame(tick);
    }
    function sync() {
      if (canRun() && !raf) {
        last = null;
        raf = win.requestAnimationFrame(tick);
      } else if (!canRun() && raf) {
        win.cancelAnimationFrame(raf);
        raf = 0;
        last = null;
      }
    }
    function settle(seconds = 1.6) {
      settlingUntil = clock + seconds;
      sync();
    }
    function greet() {
      engine.greet(clock);
      settle(3.2);
    }
    let externalAttention = { x: 0, y: 0, active: false };
    function pointer(event) {
      engine.setAttention(true, clock);
      const rect = element.getBoundingClientRect();
      engine.setLook(
        ((event.clientX - rect.left) / rect.width) * 2 - 1,
        ((event.clientY - rect.top) / rect.height) * 2 - 1,
        clock,
      );
      settle();
    }
    function leave() {
      engine.setAttention(externalAttention.active, clock);
      engine.setLook(externalAttention.x, externalAttention.y, clock);
      settle(2);
    }
    function preference() {
      api.setReducedMotion(media.matches);
    }
    const observer = new win.IntersectionObserver((entries) => {
      visible = entries[0].isIntersecting;
      sync();
    });
    observer.observe(element);
    element.addEventListener('click', greet);
    element.addEventListener('pointermove', pointer);
    element.addEventListener('pointerleave', leave);
    element.addEventListener('focus', greet);
    doc.addEventListener('visibilitychange', sync);
    media.addEventListener('change', preference);
    const api = {
      setAttention({ x = 0, y = 0, active = false } = {}) {
        externalAttention = { x: active ? x : 0, y: active ? y : 0, active };
        engine.setAttention(active, clock);
        engine.setLook(externalAttention.x, externalAttention.y, clock);
        settle(2);
      },
      setMood(mood) {
        engine.setMood(mood, clock);
        element.dataset.mood = mood;
        settle(1.8);
      },
      setActive(value) {
        active = Boolean(value);
        sync();
      },
      setReducedMotion(value) {
        reduced = Boolean(value);
        draw();
        sync();
      },
      destroy() {
        destroyed = true;
        sync();
        observer.disconnect();
        element.removeEventListener('click', greet);
        element.removeEventListener('pointermove', pointer);
        element.removeEventListener('pointerleave', leave);
        element.removeEventListener('focus', greet);
        doc.removeEventListener('visibilitychange', sync);
        media.removeEventListener('change', preference);
        element.replaceChildren();
      },
    };
    draw();
    sync();
    return api;
  }
  globalThis.HardPauseMascot = { mount, Engine };
})();
