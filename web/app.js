'use strict';

(() => {
  if (typeof document === 'undefined') return;
  document.querySelectorAll('.mascot').forEach((element) => {
    globalThis.HardPauseMascot.mount(element, { mood: 'calm' });
  });
})();
