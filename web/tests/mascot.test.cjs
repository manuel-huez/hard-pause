const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');
const context = {};
runInNewContext(readFileSync(join(__dirname, '../mascot/mascot.js'), 'utf8'), context);
const { Engine } = context.HardPauseMascot;
const numbers = (path) => path.match(/-?\d+(?:\.\d+)?/g).map(Number);

test('travelling body geometry changes top, middle and base continuously', () => {
  const engine = new Engine();
  const a = numbers(engine.sample(0).path),
    b = numbers(engine.sample(2).path);
  assert.deepEqual(a.slice(0, 2), a.slice(-2));
  assert.equal(a.length, b.length);
  for (const start of [0, 60, 180, 240]) {
    assert.ok(a.slice(start, start + 50).some((n, i) => Math.abs(n - b[start + i]) > 1));
  }
  const close = numbers(engine.sample(2.001).path);
  assert.ok(close.every((n, i) => Math.abs(n - b[i]) < 0.1));
});

test('interrupted mood and gaze transitions start at the currently drawn pose', () => {
  const engine = new Engine();
  engine.setMood('resting', 1);
  engine.setLook(1, -1, 1);
  const before = engine.sample(1.5);
  engine.setMood('waiting', 1.5);
  engine.setLook(-1, 1, 1.5);
  const after = engine.sample(1.5);
  assert.equal(after.path, before.path);
  assert.equal(after.face, before.face);
  assert.equal(after.open, before.open);
  assert.notEqual(engine.sample(2).path, before.path);
  assert.notEqual(engine.sample(2).eyes[0], before.eyes[0]);
});

test('reduced motion holds body and retains smooth mood expression feedback', () => {
  const engine = new Engine();
  assert.equal(engine.sample(0, true).path, engine.sample(8, true).path);
  engine.setMood('resting', 8);
  const first = engine.sample(8, true),
    middle = engine.sample(8.75, true),
    last = engine.sample(10, true);
  assert.equal(first.path, last.path);
  assert.ok(first.open < middle.open && middle.open < last.open);
});

test('sleeping mascot drifts staggered Zs and hides them with reduced motion', () => {
  const sleeping = new Engine();
  const first = sleeping.sample(0).sleepZ;
  const later = sleeping.sample(1).sleepZ;
  assert.equal(first.length, 3);
  assert.ok(first.every(({ opacity }) => opacity === 0));
  assert.ok(later.some(({ opacity }) => opacity > 0));
  assert.ok(first.some(({ opacity }) => opacity === 0));
  assert.notDeepEqual(later, first);
  assert.ok(later.every(({ opacity }) => opacity >= 0 && opacity <= 0.78));

  const awake = new Engine('resting').sample(0).sleepZ;
  assert.ok(awake.every(({ opacity }) => opacity === 0));
  const reduced = sleeping.sample(0, true).sleepZ;
  assert.ok(reduced.every(({ opacity }) => opacity === 0));
  assert.deepEqual(reduced, sleeping.sample(8, true).sleepZ);
});

test('sleep letters fade continuously through waking and falling asleep', () => {
  const engine = new Engine();
  engine.setAttention(true, 1);
  engine.setAttention(false, 2);
  let previous = engine.sample(2).sleepZ;
  for (let t = 2.01; t < 8; t += 0.01) {
    const current = engine.sample(t).sleepZ;
    current.forEach((z, i) => assert.ok(Math.abs(z.opacity - previous[i].opacity) < 0.025));
    previous = current;
  }
  assert.ok(engine.sample(2).sleepZ.every(({ opacity }) => opacity === 0));
  assert.ok(engine.sample(4.8).sleepZ.some(({ opacity }) => opacity > 0));
});

test('falling asleep restarts letters one at a time on the body', () => {
  const engine = new Engine();
  engine.setAttention(true, 20);
  engine.setAttention(false, 22);
  assert.ok(engine.sample(23.66).sleepZ.every(({ opacity }) => opacity === 0));
  const first = engine.sample(24.66).sleepZ;
  assert.equal(first.filter(({ opacity }) => opacity > 0).length, 1);
  const [, x, y] = first[0].transform.match(/translate\(([\d.]+) ([\d.]+)\)/);
  assert.ok(Number(x) >= 140 && Number(x) <= 190);
  assert.ok(Number(y) >= 110 && Number(y) <= 145);
});

test('greeting opens gradually and returns without a pose snap', () => {
  const engine = new Engine();
  const first = engine.sample(1);
  engine.greet(1);
  assert.equal(engine.sample(1).open, first.open);
  assert.ok(engine.sample(2.2).open > 0.8);
  assert.ok(Math.abs(engine.sample(4.089).open - engine.sample(4.09).open) < 0.001);
});

test('greeting makes two quick nods and reduced motion keeps only the expression', () => {
  const engine = new Engine('resting');
  engine.greet(1);
  assert.equal(engine.sample(1).character, 'translate(0 0)');
  assert.equal(engine.sample(1.26).character, 'translate(0 0)');
  assert.equal(engine.sample(1.356).character, 'translate(0 3)');
  assert.equal(engine.sample(1.5).character, 'translate(0 0)');
  assert.equal(engine.sample(1.596).character, 'translate(0 3)');
  const returning = Number(engine.sample(1.68).character.match(/translate\(0 ([\d.]+)\)/)[1]);
  assert.ok(returning > 0 && returning < 3);
  assert.equal(engine.sample(2.06).character, 'translate(0 0)');

  const reducedStart = engine.sample(1, true);
  const reducedSmile = engine.sample(1.45, true);
  assert.equal(reducedStart.character, 'translate(0 0)');
  assert.equal(reducedSmile.character, 'translate(0 0)');
  assert.equal(reducedStart.path, reducedSmile.path);
  assert.notEqual(reducedStart.mouth, reducedSmile.mouth);
});

test('greeting faces forward, nods, then follows the latest moving target without jumps', () => {
  const engine = new Engine('resting');
  engine.setLook(1, -0.5, 0);
  const before = engine.sample(0.3);
  engine.greet(0.3);
  const start = engine.sample(0.3);
  assert.deepEqual(start.gaze, before.gaze);
  assert.deepEqual(start.torso, before.torso);

  const centered = engine.sample(0.56);
  near(centered.greetingFocus, 1);
  near(centered.gaze.x, 0);
  near(centered.gaze.y, 0);
  near(centered.torso.x, 0);
  near(centered.torso.y, 0);
  assert.equal(centered.character, 'translate(0 0)');
  assert.equal(engine.sample(0.656).character, 'translate(0 3)');

  for (let step = 1; step <= 20; step++) {
    const time = 0.7 + step / 100;
    const drawn = engine.sample(time);
    engine.setLook(1 - step / 10, -0.5 + step / 16, time);
    const retargeted = engine.sample(time);
    assert.equal(retargeted.path, drawn.path);
    assert.equal(retargeted.face, drawn.face);
  }
  const returnStart = engine.sample(1.04);
  near(returnStart.greetingFocus, 1);
  near(returnStart.gaze.x, 0);
  const returningGaze = engine.sample(1.24);
  assert.ok(returningGaze.gaze.x < 0 && returningGaze.gaze.x > -28);
  assert.ok(returningGaze.torso.x < 0 && returningGaze.torso.x > -28);
  const returned = engine.sample(1.44);
  near(returned.greetingFocus, 0);
  near(returned.gaze.x, -28);
  near(returned.gaze.y, 15);
  near(returned.torso.x, -28);
  near(returned.torso.y, 15);
});

test('greeting queues one later action during the nod and can restart after the motion settles', () => {
  const engine = new Engine('resting');
  engine.greet(1);
  engine.greet(1.3);
  assert.equal(engine.greetingQueued, true);
  assert.equal(engine.sample(2.13).character, 'translate(0 0)');
  engine.sample(2.14);
  near(engine.helloAt, 2.14);
  assert.equal(engine.greetingQueued, false);
  assert.equal(engine.sample(2.496).character, 'translate(0 3)');

  const settledMotion = new Engine('resting');
  settledMotion.greet(1);
  settledMotion.greet(2.6);
  near(settledMotion.helloAt, 2.6);
});

test('attention wakes and sleeps gradually and can reverse without a jump', () => {
  const engine = new Engine();
  const initial = engine.sample(1, true).open;
  engine.setAttention(true, 1);
  assert.equal(engine.sample(1, true).open, initial);
  const middle = engine.sample(1.45, true).open;
  assert.ok(middle > initial && middle < engine.sample(1.9, true).open);
  engine.setAttention(false, 1.45);
  assert.equal(engine.sample(1.45, true).open, middle);
  assert.ok(engine.sample(2, true).open < middle);
  assert.equal(engine.sample(3.5, true).open, initial);
});

test('mood, attention and greeting preserve base geometry while the nod moves its wrapper', () => {
  const calm = new Engine();
  const active = new Engine();
  active.setMood('resting', 0);
  active.setAttention(true, 0);
  active.greet(1);
  for (const time of [0, 0.45, 1.54, 2.2, 5]) {
    const a = calm.sample(time),
      b = active.sample(time);
    assert.equal(a.path, b.path);
    assert.deepEqual(a.light, b.light);
    assert.deepEqual(a.moon, b.moon);
    assert.equal(a.roll, b.roll);
  }
  assert.notEqual(calm.sample(1.54).eyes[0], active.sample(1.54).eyes[0]);
  assert.notEqual(calm.sample(1.54).character, active.sample(1.54).character);
});

test('pointer leave uses a slower smooth return than active gaze following', () => {
  const engine = new Engine('resting');
  engine.setLook(1, 0.5, 0);
  assert.ok(engine.look(0.05).x > 27);
  near(engine.look(0.1).x, 28);
  engine.setLook(0, 0, 0.3, true);
  near(engine.look(0.3).x, 28);
  assert.ok(engine.look(0.4).x > 20);
  assert.ok(engine.look(0.5).x > 10 && engine.look(0.5).x < 18);
  near(engine.look(0.7).x, 0);
  near(engine.torsoLook(0.7).x, 0);
});

test('awake eyes remain readable at native size and mouth shares gaze projection', () => {
  const engine = new Engine();
  engine.setAttention(true, 0);
  const awake = engine.sample(1, true);
  const eye = numbers(awake.eyes[0]);
  const x = eye.filter((_, i) => i % 2 === 0),
    y = eye.filter((_, i) => i % 2 === 1);
  const width = Math.max(...x) - Math.min(...x);
  const height = Math.max(...y) - Math.min(...y);
  assert.ok(width > 12 && width < 15);
  assert.ok(height > width);
  assert.equal(awake.face, 'translate(199 221) rotate(0) scale(0.9)');
  engine.setLook(1, 0.5, 1);
  const turned = engine.sample(2, true);
  assert.notEqual(turned.mouth, awake.mouth);
  assert.notEqual(turned.eyes[0], awake.eyes[0]);
  assert.notEqual(turned.face, awake.face);
});

test('blinks close fast, reopen softly and follow an irregular schedule', () => {
  const engine = new Engine('resting');
  assert.ok(engine.sample(2.375).blink < 0.001);
  assert.ok(engine.sample(2.3375).blink > engine.sample(2.4125).blink);
  assert.equal(engine.sample(2.52).blink, 1);
  const starts = [];
  let inside = false;
  for (let time = 0; time < 25; time += 0.01) {
    const closed = engine.sample(time).blink < 0.1;
    if (closed && !inside) starts.push(time);
    inside = closed;
  }
  assert.ok(starts.length >= 6);
  const intervals = starts.slice(1).map((t, i) => Math.round((t - starts[i]) * 10));
  assert.ok(new Set(intervals).size > 3);
  assert.equal(engine.sample(2.375, true).blink, 1);
});

test('gaze responds on the next frame and settles quickly without retarget jumps', () => {
  const engine = new Engine();
  engine.setLook(1, 0.5, 1);
  assert.equal(engine.look(1).x, 0);
  assert.ok(engine.look(1 + 1 / 30).x > 13);
  assert.ok(engine.look(1.08).x > 15.8);
  const before = engine.sample(1.08);
  engine.setLook(-1, -0.5, 1.08);
  const after = engine.sample(1.08);
  assert.equal(after.face, before.face);
  assert.equal(after.mouth, before.mouth);
  assert.deepEqual(after.eyes, before.eyes);
  assert.ok(engine.look(1.23).x < -15.8);
  // Duplicate input/selection notifications must not restart an active follow.
  const expected = engine.look(1.24);
  const expectedTorso = engine.torsoLook(1.24);
  engine.setLook(-1, -0.5, 1.12);
  assert.deepEqual(engine.look(1.24), expected);
  assert.deepEqual(engine.torsoLook(1.24), expectedTorso);
});

const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 0.00001);
function sleepyGeometry(frame) {
  near(frame.eyeGeometry.width, 17.5);
  near(frame.eyeGeometry.curve, 8.7);
  near(frame.eyeGeometry.height, 0);
  near(frame.eyeGeometry.shape, 0);
  assert.equal(frame.blink, 1);
}

test('sleep quickly morphs to full sleepy curves, back to half-open eyes, then slowly to sleep', () => {
  const engine = new Engine();
  engine.setAttention(true, 0);
  engine.setAttention(false, 1);
  near(engine.sample(1).eyeGeometry.shape, 1);
  sleepyGeometry(engine.sample(1.12));
  near(engine.sample(1.26).eyeGeometry.shape, 0.55);
  near(engine.sample(1.26).eyeGeometry.width, 17.5 + (6.6 - 17.5) * 0.55);
  const middle = engine.sample(1.9).eyeGeometry;
  assert.ok(middle.shape > 0 && middle.shape < 1);
  assert.ok(middle.width > 6.6 && middle.width < 17.5);
  sleepyGeometry(engine.sample(2.66));
});

test('each stage retargets from its full current eye shape when focus resumes', () => {
  for (const time of [1.06, 1.12, 1.19, 1.26, 1.9]) {
    const engine = new Engine();
    engine.setAttention(true, 0);
    engine.setAttention(false, 1);
    const before = engine.sample(time);
    engine.setAttention(true, time);
    const after = engine.sample(time);
    assert.deepEqual(after.eyes, before.eyes);
    assert.deepEqual(after.eyeGeometry, before.eyeGeometry);
    assert.equal(after.path, before.path);
    near(engine.sample(time + 1).eyeGeometry.shape, 1);
  }
});

test('greeting end uses the same geometry sequence and never sleeps while focused', () => {
  const engine = new Engine();
  engine.greet(1);
  near(engine.sample(2.3).eyeGeometry.shape, 1);
  sleepyGeometry(engine.sample(2.57));
  near(engine.sample(2.71).eyeGeometry.shape, 0.55);
  sleepyGeometry(engine.sample(4.11));
  const before = engine.sample(2.57);
  engine.setAttention(true, 2.57);
  assert.deepEqual(engine.sample(2.57).eyes, before.eyes);
  near(engine.sample(4.2).eyeGeometry.shape, 1);
  const focused = new Engine();
  focused.setAttention(true, 0);
  focused.greet(1);
  for (const time of [2.57, 2.71, 4.11]) near(focused.sample(time).eyeGeometry.shape, 1);
});

test('break-to-calm geometry sequences only when not focused; reduced motion skips quick stages', () => {
  const engine = new Engine('resting');
  engine.setMood('calm', 1);
  sleepyGeometry(engine.sample(1.12));
  near(engine.sample(1.26).eyeGeometry.shape, 0.9 * 0.55);
  sleepyGeometry(engine.sample(2.66));
  const attentive = new Engine('resting');
  attentive.setAttention(true, 0);
  attentive.setMood('calm', 1);
  near(attentive.sample(1.12).eyeGeometry.shape, 1);
  const reduced = new Engine();
  reduced.setAttention(true, 0);
  reduced.setAttention(false, 1);
  const shapes = [1, 1.12, 1.26, 1.9, 2.4].map(
    (time) => reduced.sample(time, true).eyeGeometry.shape,
  );
  assert.ok(shapes.every((shape, i) => i === 0 || shape < shapes[i - 1]));
  near(shapes.at(-1), 0);
});

test('native sleeping and awake first frames match their initial live renderer geometry', () => {
  const round = (n) => Math.round(n * 100) / 100;
  for (const [name, mood] of [
    ['first-frame.svg', 'calm'],
    ['first-frame-awake.svg', 'resting'],
  ]) {
    const svg = readFileSync(join(__dirname, `../mascot/${name}`), 'utf8');
    const asset = mood === 'resting' ? 'LowLightCharacterAwake' : 'LowLightCharacter';
    assert.equal(
      readFileSync(
        join(__dirname, `../../ios/App/Assets.xcassets/${asset}.imageset/low-light-character.svg`),
        'utf8',
      ),
      svg,
    );
    const frame = new Engine(mood).sample(0);
    for (const path of [frame.path, ...frame.eyes, frame.mouth])
      assert.ok(svg.includes(`d="${path}"`), `${name} is missing renderer path`);
    assert.ok(svg.includes(`transform="${frame.face}"`));
    assert.ok(svg.includes(`cx="${round(frame.light[0])}" cy="${round(frame.light[1])}" r="225"`));
    assert.ok(svg.includes(`transform="${frame.moon}"`));
    assert.ok(!svg.includes('low-light-arm'));
  }
});

test('gaze deforms upper lobes after the face and keeps the lower edge anchored', () => {
  const engine = new Engine('resting');
  const neutral = new Engine('resting');
  engine.setLook(1, 1, 0);
  assert.equal(engine.look(0.1).x, 28);
  assert.equal(engine.look(0.1).y, 20);
  assert.ok(engine.torsoLook(0.1).x > 0 && engine.torsoLook(0.1).x < 28);
  assert.equal(engine.torsoLook(0.3).x, 28);
  assert.equal(engine.sample(0.3).character, 'translate(0 0)');

  const base = numbers(neutral.sample(0.3).path);
  const moved = numbers(engine.sample(0.3).path);
  const upper = [];
  const lower = [];
  for (let index = 0; index < base.length; index += 2) {
    const delta = { x: moved[index] - base[index], y: moved[index + 1] - base[index + 1] };
    if (base[index + 1] < 175) upper.push(delta);
    if (base[index + 1] > 300) lower.push(delta);
  }
  assert.ok(upper.reduce((sum, point) => sum + point.x, 0) / upper.length > 4);
  assert.ok(upper.reduce((sum, point) => sum + point.y, 0) / upper.length > 2);
  assert.ok(lower.every((point) => Math.abs(point.x) < 1 && Math.abs(point.y) < 1));
  const upperWidth = (values) => {
    const xs = [];
    for (let index = 0; index < values.length; index += 2)
      if (values[index + 1] < 175) xs.push(values[index]);
    return Math.max(...xs) - Math.min(...xs);
  };
  assert.ok(upperWidth(moved) < upperWidth(base));

  const reduced = engine.sample(0.3, true);
  const reducedNeutral = neutral.sample(0.3, true);
  assert.equal(reduced.path, reducedNeutral.path);
  assert.equal(reduced.character, 'translate(0 0)');
  assert.notEqual(reduced.face, reducedNeutral.face);
});

test('torso gaze reverses from the currently drawn contour without a jump', () => {
  const engine = new Engine('resting');
  engine.setLook(1, 0.5, 1);
  const before = engine.sample(1.15);
  const torsoBefore = engine.torsoLook(1.15);
  engine.setLook(-1, -0.5, 1.15);
  const after = engine.sample(1.15);
  assert.deepEqual(engine.torsoLook(1.15), torsoBefore);
  assert.equal(after.path, before.path);
  assert.equal(after.face, before.face);
  assert.deepEqual(after.eyes, before.eyes);
  assert.equal(after.mouth, before.mouth);
  assert.equal(engine.torsoLook(1.45).x, -28);
});

test('torso gaze continues following frequent pointer targets without accumulated lag', () => {
  const engine = new Engine('resting');
  engine.setLook(-1, 0, 0);
  near(engine.torsoLook(0.3).x, -28);
  for (let step = 1; step <= 100; step++) {
    const time = 0.3 + step / 100;
    engine.setLook(-1 + step / 50, 0, time);
  }
  assert.ok(engine.torsoLook(1.3).x > 20);
  assert.ok(engine.torsoLook(1.45).x > 27);
});
