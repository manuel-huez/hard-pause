const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './web/tests',
  testMatch: '**/*.spec.cjs',
  use: {
    baseURL: 'http://127.0.0.1:4175',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1280, height: 900 } } },
    {
      name: 'phone',
      use: { viewport: { width: 320, height: 740 }, isMobile: true, hasTouch: true },
    },
  ],
  webServer: {
    command: 'node scripts/serve-web.cjs',
    url: 'http://127.0.0.1:4175',
    reuseExistingServer: false,
  },
});
