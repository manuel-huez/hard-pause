const { readFileSync } = require('node:fs');
const { join } = require('node:path');
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
  await expect(page.getByRole('heading', { name: 'Pause', exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Hard Pause', exact: true })).toBeVisible();
  await expect(
    page.getByText('We still need to test the protection on a real iPhone.'),
  ).toBeVisible();
  await expect(
    page.getByText('The Mac download is a development build.', { exact: false }),
  ).toBeVisible();
  await expect(page.getByRole('link', { name: 'download for Mac' })).toHaveAttribute(
    'href',
    `${repositoryURL}/releases/latest`,
  );
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
  await expect(page.getByRole('link', { name: 'get the app' })).toBeVisible();
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

test('native 120 px renderer starts awake from the resting URL and keeps its face readable', async ({
  page,
}) => {
  await page.setViewportSize({ width: 120, height: 114 });
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.goto('/mascot/native.html#resting');
  await expect(page.locator('html')).toHaveAttribute('data-renderer-ready', 'true');

  await expect
    .poll(async () => {
      const eyeBoxes = await page.locator('.low-light-eye').evaluateAll((eyes) =>
        eyes.map((eye) => {
          const box = eye.getBoundingClientRect();
          return { width: box.width, height: box.height };
        }),
      );
      return eyeBoxes.length === 2 && eyeBoxes.every((box) => box.width > 3 && box.height > 4);
    })
    .toBe(true);
  const mouthBox = await page.locator('.low-light-mouth').evaluate((mouth) => {
    const box = mouth.getBoundingClientRect();
    return { width: box.width, height: box.height };
  });
  expect(mouthBox.width).toBeGreaterThan(4);
  expect(mouthBox.height).toBeGreaterThan(1);
});

test('native greeting API faces forward, nods, and returns to the latest target', async ({
  page,
}) => {
  await page.goto('/mascot/native.html#resting');
  await expect(page.locator('html')).toHaveAttribute('data-renderer-ready', 'true');
  const result = await page.evaluate(async () => {
    const face = document.querySelector('.low-light-face');
    const character = document.querySelector('.low-light-character');
    const faceX = () => Number(face.getAttribute('transform').match(/translate\(([-\d.]+)/)[1]);
    globalThis.hardPauseMascot.setAttention({ x: 1, y: -0.4, active: true });
    await new Promise((resolve) => globalThis.setTimeout(resolve, 400));
    const initialX = faceX();
    globalThis.hardPauseMascot.greet();
    const frames = [];
    for (let index = 0; index < 32; index++) {
      if (index === 9) globalThis.hardPauseMascot.setAttention({ x: -1, y: 0.5, active: true });
      await new Promise((resolve) => globalThis.setTimeout(resolve, 50));
      frames.push({
        x: faceX(),
        character: character.getAttribute('transform'),
      });
    }
    return { initialX, frames };
  });
  expect(result.initialX).toBeGreaterThan(220);
  for (const frame of result.frames.slice(5, 14)) expect(Math.abs(frame.x - 200)).toBeLessThan(5);
  expect(result.frames.at(-1).x).toBeLessThan(180);
  const positions = result.frames.map(({ character }) =>
    Number(character.match(/translate\(0 ([\d.]+)\)/)[1]),
  );
  const peaks = positions.filter(
    (position, index) =>
      position > 2.5 && position > positions[index - 1] && position >= positions[index + 1],
  );
  expect(peaks).toHaveLength(2);
  expect(positions.at(-1)).toBe(0);

  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-renderer-ready', 'true');
  const mouth = page.locator('.low-light-mouth');
  const body = page.locator('.low-light-body');
  await page.evaluate(() =>
    globalThis.hardPauseMascot.setAttention({ x: 1, y: 0.5, active: true }),
  );
  await page.waitForTimeout(500);
  const initialBody = await body.getAttribute('d');
  const initialMouth = await mouth.getAttribute('d');
  await page.evaluate(() => globalThis.hardPauseMascot.greet());
  await page.waitForTimeout(500);
  await expect(page.locator('.low-light-character')).toHaveAttribute('transform', 'translate(0 0)');
  expect(await body.getAttribute('d')).toBe(initialBody);
  expect(await mouth.getAttribute('d')).not.toBe(initialMouth);
});

test('RTA check reads only an exact rating tag in the page head', async ({ page }) => {
  const source = readFileSync(join(__dirname, '../../macos/Core/AdultWebsiteRules.swift'), 'utf8');
  const script = source.match(/static let script = """([\s\S]*?)"""/)[1];
  await page.setContent(
    '<head><meta NAME="RaTiNg" content=" rta-5042-1996-1400-1577-rta "></head><body></body>',
  );
  expect(await page.evaluate(script)).toBe(true);
  await page.setContent(
    '<head><meta http-equiv="Rating" content="RTA-5042-1996-1400-1577-RTA"></head>',
  );
  expect(await page.evaluate(script)).toBe(true);
  for (const markup of [
    '<head></head><body>RTA-5042-1996-1400-1577-RTA</body>',
    '<head><!-- <meta name="rating" content="RTA-5042-1996-1400-1577-RTA"> --></head>',
    '<head><meta name="description" content="RTA-5042-1996-1400-1577-RTA"></head>',
    '<head><meta name="rating" content="NOT-RTA-5042-1996-1400-1577-RTA"></head>',
  ]) {
    await page.setContent(markup);
    expect(await page.evaluate(script)).toBe(false);
  }
});
