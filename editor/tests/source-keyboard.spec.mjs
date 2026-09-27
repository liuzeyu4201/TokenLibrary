import { test, expect } from '@playwright/test';

const original = 'Keyboard route\n\nBody stays here.\n';
async function openSource(page) {
  await page.goto('/');
  await page.waitForFunction(() => window.tlEditorReady);
  await page.evaluate(text => {
    window.tlSetMarkdown(text);
    window.changes = [];
    window.addEventListener('tl-change', event => window.changes.push(event.detail));
  }, original);
  await page.getByRole('button', { name: '源码', exact: true }).click();
  const source = page.getByRole('textbox', { name: 'Markdown 源码' });
  await source.focus();
  await page.keyboard.press('ControlOrMeta+End');
  return source;
}

test('source keyboard Tab indents but Shift-Tab leaves without editing', async ({ page }) => {
  const source = await openSource(page);
  await page.keyboard.press('Tab');
  await expect(source).toBeFocused();
  await expect(source).toHaveValue(original + '    ');
  await page.keyboard.press('Shift+Tab');
  await expect(source).not.toBeFocused();
  await expect(page.getByRole('button', { name: '流程图', exact: true })).toBeFocused();
  await expect(source).toHaveValue(original + '    ');
  expect(await page.evaluate(() => window.changes)).toEqual([original + '    ']);
});

test('source keyboard Escape then Tab exits forward once and preserves the draft', async ({ page }) => {
  const source = await openSource(page);
  // A real error control after the editor gives forward traversal an in-page
  // destination. This uses the public failure callback, not a synthetic sentinel.
  await page.evaluate(() => window.tlSaved(false, '合成保存失败'));
  await page.keyboard.press('Escape');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('button', { name: '重试保存', exact: true })).toBeFocused();
  await expect(source).toHaveValue(original);
  expect(await page.evaluate(() => window.changes)).toEqual([]);
  await page.keyboard.press('Shift+Tab');
  await expect(source).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(source).toBeFocused();
  await expect(source).toHaveValue(original + '    ');
});

test('source keyboard escape is cleared by typing, blur, mode changes, remote updates and reopening', async ({ page }) => {
  for (const reset of ['typing', 'blur', 'mode', 'remote', 'reopen']) {
    let source = await openSource(page);
    await page.keyboard.press('Escape');
    let expected = original;
    if (reset === 'typing') {
      await page.keyboard.type('x'); expected += 'x';
    } else if (reset === 'blur') {
      await page.getByRole('button', { name: '源码', exact: true }).focus();
      await source.focus();
    } else if (reset === 'mode') {
      await page.getByRole('button', { name: '阅读', exact: true }).click();
      await page.getByRole('button', { name: '源码', exact: true }).click();
      await source.focus();
    } else if (reset === 'remote') {
      expected = original.replace('Keyboard route', 'Remote keyboard route');
      expect(await page.evaluate(text => window.tlAcceptUpdate(text), expected)).toBe(true);
    } else {
      source = await openSource(page);
    }
    // No extra key after Escape/reset that could mask a stale one-shot flag.
    await page.keyboard.press('Tab');
    await expect(source, reset).toBeFocused();
    await expect(source, reset).toHaveValue(expected + '    ');
  }
});

test('source keyboard Escape during composition remains available to the input method', async ({ page }) => {
  const source = await openSource(page);
  await source.evaluate(element => {
    window.escapePrevented = null;
    window.addEventListener('keydown', event => {
      if (event.key === 'Escape') window.escapePrevented = event.defaultPrevented;
    });
    element.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
  });
  // Composition state is a protocol fixture; Escape itself is a real browser
  // keypress. This is not a claim about a physical macOS/iOS IME session.
  await page.keyboard.press('Escape');
  expect(await page.evaluate(() => window.escapePrevented)).toBe(false);
  await expect(source).toHaveValue(original);
  await source.evaluate(element => element.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' })));
  await page.keyboard.press('Tab');
  await expect(source).toBeFocused();
  await expect(source).toHaveValue(original + '    ');
});

test('source keyboard escape route is discoverable without changing the saved body', async ({ page }) => {
  const source = await openSource(page);
  await expect(source).toHaveAccessibleDescription(/Esc 后按 Tab 可离开源码区/);
  await expect(page.locator('#source-keyboard-help')).toBeVisible();
  await page.getByRole('button', { name: '阅读', exact: true }).click();
  await expect(page.locator('#source-keyboard-help')).toBeHidden();
  expect(await page.evaluate(() => window.tlGetMarkdown())).toBe(original);
  expect(await page.evaluate(() => window.changes)).toEqual([]);
});
