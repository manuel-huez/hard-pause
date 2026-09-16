'use strict';
const requestedMood = globalThis.location.hash.slice(1);
const initialMood = ['resting', 'waiting'].includes(requestedMood) ? requestedMood : 'calm';
globalThis.hardPauseMascot = globalThis.HardPauseMascot.mount(document.getElementById('mascot'), {
  mood: initialMood,
});

globalThis.requestAnimationFrame(() => {
  globalThis.requestAnimationFrame(() => {
    document.documentElement.dataset.rendererReady = 'true';
    globalThis.webkit?.messageHandlers?.hardPauseMascotReady?.postMessage(true);
  });
});
