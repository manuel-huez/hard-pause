'use strict';
globalThis.hardPauseMascot = globalThis.HardPauseMascot.mount(document.getElementById('mascot'), {
  mood: 'calm',
});

globalThis.requestAnimationFrame(() => {
  globalThis.requestAnimationFrame(() => {
    document.documentElement.dataset.rendererReady = 'true';
    globalThis.webkit?.messageHandlers?.hardPauseMascotReady?.postMessage(true);
  });
});
