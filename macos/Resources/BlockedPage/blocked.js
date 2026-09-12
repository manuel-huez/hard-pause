'use strict';

/* global document */

const mascotTarget = document.getElementById('mascot');
if (mascotTarget && globalThis.HardPauseMascot) {
  const mascot = globalThis.HardPauseMascot.mount(mascotTarget, { mood: 'waiting' });
  globalThis.addEventListener('pagehide', () => mascot.destroy(), { once: true });
}
