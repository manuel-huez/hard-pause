const { test, expect } = require('@playwright/test');

const repositoryURL = 'https://github.com/manuel-huez/hard-pause';
const checksURL = `${repositoryURL}/actions/workflows/checks.yml`;

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    globalThis.__cspViolations = [];
    document.addEventListener('securitypolicyviolation', (event) => {
      globalThis.__cspViolations.push(`${event.violatedDirective}: ${event.blockedURI}`);
    });
  });
});

test.afterEach(async ({ page }) => {
  expect(await page.evaluate(() => globalThis.__cspViolations || [])).toEqual([]);
});

test('production landing is honest, local, and contains no simulated controls', async ({
  page,
}) => {
  const errors = [];
  const external = [];
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('request', (request) => {
    if (new URL(request.url()).hostname !== '127.0.0.1') external.push(request.url());
  });

  await page.goto('/');
  await expect(page.getByRole('heading', { name: 'Nothing needs you right now.' })).toBeVisible();
  await expect(
    page.getByText('Hard Pause uses local system protection designed for each device.'),
  ).toBeVisible();
  await expect(page.getByText('iOS 26 or later')).toBeVisible();
  await expect(page.getByText('macOS 26 or later')).toBeVisible();
  await expect(page.getByText('A public installer is not available yet.')).toBeVisible();
  await expect(page.getByRole('link', { name: 'view the source' })).toHaveAttribute(
    'href',
    repositoryURL,
  );
  await expect(page.getByRole('link', { name: 'view build checks' })).toHaveAttribute(
    'href',
    checksURL,
  );
  await expect(page.locator('.product-illustration')).toHaveAttribute('role', 'img');
  await expect(
    page.locator('.product-illustration button, .product-illustration input'),
  ).toHaveCount(0);
  await expect(page.locator('form, input, select')).toHaveCount(0);
  await expect(page.locator('[id*="preview"], [class*="preview"]')).toHaveCount(0);
  expect((await page.locator('body').innerText()).toLowerCase()).not.toContain('skip the wait');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(
    true,
  );
  expect(errors).toEqual([]);
  expect(external).toEqual([]);
});

test('Low Light keeps the sleeping motion and respects reduced motion', async ({ page }) => {
  await page.goto('/');
  const liveBody = page.locator('.presence .low-light-body');
  await expect(liveBody).toHaveAttribute('d', /Z$/);
  const movingPaths = await liveBody.evaluate(async (shape) => {
    const paths = [];
    for (let index = 0; index < 8; index++) {
      await new Promise((resolve) => globalThis.setTimeout(resolve, 50));
      paths.push(shape.getAttribute('d'));
    }
    return paths;
  });
  expect(new Set(movingPaths).size).toBeGreaterThan(3);

  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.waitForTimeout(100);
  const stillPath = await liveBody.getAttribute('d');
  await page.waitForTimeout(250);
  expect(await liveBody.getAttribute('d')).toBe(stillPath);
  await expect(page.locator('.presence .low-light-svg')).toHaveCSS('animation-name', 'none');
});

test('landing fits a narrow viewport and enlarged text', async ({ page }) => {
  await page.goto('/');
  await page.evaluate(() => {
    document.body.style.zoom = '2';
  });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(
    true,
  );
  await expect(page.getByRole('link', { name: 'get the source' })).toBeVisible();
});

test('bundled native renderer remains local and morphs without body zoom', async ({ page }) => {
  const errors = [];
  const external = [];
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('request', (request) => {
    if (new URL(request.url()).hostname !== '127.0.0.1') external.push(request.url());
  });

  await page.goto('/mascot/native.html');
  await expect(page.locator('html')).toHaveAttribute('data-renderer-ready', 'true');
  const body = page.locator('.low-light-body');
  await expect(body).toHaveAttribute('d', /Z$/);
  const paths = await body.evaluate(async (shape) => {
    const values = [];
    for (let index = 0; index < 12; index++) {
      await new Promise((resolve) => globalThis.setTimeout(resolve, 50));
      values.push(shape.getAttribute('d'));
    }
    return values;
  });
  expect(new Set(paths).size).toBeGreaterThan(5);

  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.waitForTimeout(100);
  const initialPath = await body.getAttribute('d');
  const initialBox = await body.boundingBox();
  await page.locator('#mascot').hover();
  await page.waitForTimeout(1100);
  expect(await body.getAttribute('d')).toBe(initialPath);
  const hoveredBox = await body.boundingBox();
  expect(hoveredBox.width).toBeCloseTo(initialBox.width, 1);
  expect(hoveredBox.height).toBeCloseTo(initialBox.height, 1);
  expect(errors).toEqual([]);
  expect(external).toEqual([]);
});
