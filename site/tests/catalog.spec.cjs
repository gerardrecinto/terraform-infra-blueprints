const { test, expect } = require('@playwright/test');
const axe = require.resolve('axe-core/axe.min.js');

test('catalog works and scrollable examples are keyboard accessible', async ({ page }) => {
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto('/');
  await page.waitForFunction(() => window.__TF_READY__);
  const cards = page.locator('#grid .m');
  const total = await cards.count();
  expect(total).toBeGreaterThan(20);
  await page.getByRole('searchbox').fill('s3_lifecycle');
  await expect(cards).toHaveCount(1);
  await expect(cards).toContainText('s3_lifecycle');
  await page.getByRole('searchbox').fill('no-such-blueprint');
  await expect(cards).toHaveCount(0);
  await page.getByRole('searchbox').fill('');
  await expect(cards).toHaveCount(total);
  const command = page.locator('#qs-code');
  await command.focus();
  await expect(command).toBeFocused();
  expect(await command.evaluate(e => getComputedStyle(e).outlineStyle)).not.toBe('none');
  await command.press('ArrowRight');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.addScriptTag({ path: axe });
  const violations = await page.evaluate(async () => (await axe.run(document, {
    runOnly: ['wcag2a', 'wcag2aa', 'wcag21aa'],
  })).violations.map(v => `${v.id}: ${v.nodes.map(n => n.target.join(' ')).join(', ')}`));
  expect(violations).toEqual([]);
  expect(errors).toEqual([]);
});

test('README fallback survives catalog failure and JavaScript disabled', async ({ page, browser }) => {
  await page.route('**/catalog.json', route => route.abort());
  await page.goto('/');
  await expect(page.locator('#kpis')).toContainText('The catalog did not load');
  const context = await browser.newContext({ javaScriptEnabled: false, baseURL: 'http://127.0.0.1:4387' });
  try {
    const p = await context.newPage();
    await p.goto('http://127.0.0.1:4387/');
    await expect(p.locator('noscript p')).toBeVisible();
    expect(await p.locator('noscript p').evaluate(e => e.innerText)).toContain('The catalog needs JavaScript.');
    await expect(p.locator('#qs-code')).toContainText('terraform validate');
    await expect(p.locator('noscript a')).toHaveAttribute('href', /#structure$/);
  } finally { await context.close(); }
});
