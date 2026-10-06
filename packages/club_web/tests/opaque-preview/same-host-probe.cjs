// Start ./scripts/dev-server.sh --dummy after building club_web.
// From repo root: node <this file> <playwright module> [archive.tar.gz] [origin]
// The optional archive must be an unmodified Flutter web build with a "Copy code"
// button that calls Clipboard.setData (for example, thinking_orbs' example app).
const { chromium } = require(process.argv[2] || 'playwright');
const { readFileSync } = require('node:fs');
const { createHash } = require('node:crypto');
const assert = require('node:assert/strict');
const origin = process.argv[4] || 'http://localhost:8080';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  let settingsPage;
  let originalDisabled;
  try {
    // Grants the browser permission only. Iframe Permissions Policy still applies.
    const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
    for (const path of ['/site-runner%2Findex.html', '/site%2Drunner%2findex.html', '/other%2f..%2fsite-runner/index.html']) {
      const response = await context.request.get(origin + path);
      assert.equal(response.status(), 404, 'Encoded paths must not bypass the runner sandbox: ' + path);
    }
    for (const path of ['/%73ite-runner/index.html', '/site%2Drunner/index.html', '/site-runner/%69ndex.html']) {
      const response = await context.request.get(origin + path);
      assert.equal(response.status(), 200, 'Encoded unreserved aliases must remain routable');
      assert.match(response.headers()['content-security-policy'] || '', /sandbox allow-scripts allow-forms;/, 'Aliases must retain opaque HTTP sandbox');
    }
    const page = await context.newPage();
    const errors = [];
    context.on('page', p => p.on('pageerror', error => errors.push(error.message)));
    await page.goto(origin + '/login');
    await page.getByLabel('Email', { exact: true }).fill('admin@localhost');
    await page.getByLabel('Password', { exact: true }).fill('admin123');
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.waitForURL(url => url.pathname !== '/login');
    settingsPage = page;
    originalDisabled = await page.evaluate(async () => (await (await fetch('/api/admin/sites/settings')).json()).disableSites);
    await page.goto(origin + '/admin/settings/sites');
    let checkbox = page.getByRole('checkbox', { name: /Enable sites/ });
    await checkbox.waitFor();
    assert.equal(await checkbox.isChecked(), !originalDisabled, 'Enable sites must invert the stored disable flag');
    if (await checkbox.isChecked()) {
      await checkbox.uncheck();
      await page.getByRole('status').filter({ hasText: 'Saved.' }).waitFor();
    }
    await page.goto(origin + '/packages/club_gallery_demo');
    assert.equal(await page.getByRole('link', { name: 'flutter', exact: true }).count(), 0, 'Disabled sites must be hidden');
    const denied = await page.evaluate(async () => {
      const response = await fetch('/api/packages/club_gallery_demo/sites/flutter/archive', { headers: { 'If-None-Match': '*' } });
      return { status: response.status, code: (await response.json()).error.code };
    });
    assert.deepEqual(denied, { status: 403, code: 'sites_disabled' }, 'Unchecked settings must deny conditional downloads');
    await page.goto(origin + '/packages/club_gallery_demo/site/flutter');
    await page.getByText('Sites are disabled on this server.', { exact: true }).waitFor();
    assert.equal(await page.locator('iframe').count(), 0, 'Disabled direct routes must not start a preview');
    await page.goto(origin + '/admin/settings/sites');
    checkbox = page.getByRole('checkbox', { name: /Enable sites/ });
    await checkbox.check();
    await page.getByRole('status').filter({ hasText: 'Saved.' }).waitFor();
    const info = await page.evaluate(async () => (await fetch('/api/packages/club_gallery_demo/sites')).json());
    assert.equal(info.runnerUrl, null, 'Regression must exercise the default without runner configuration');
    if (process.argv[3]) {
      const bytes = readFileSync(process.argv[3]);
      const etag = '"' + createHash('sha256').update(bytes).digest('hex') + '"';
      await context.route('**/api/packages/club_gallery_demo/sites/flutter/archive', route => route.fulfill({
        body: bytes, headers: { 'content-type': 'application/gzip', etag }
      }));
    }
    await page.goto(origin + '/packages/club_gallery_demo');
    const popup = context.waitForEvent('page');
    await page.getByRole('link', { name: 'flutter', exact: true }).click();
    const preview = await popup;
    await preview.waitForURL('**/site/flutter');
    await preview.locator('iframe.shown').waitFor({ timeout: 60000 });
    const runner = preview.frames().find(frame => frame.parentFrame() === preview.mainFrame());
    const content = preview.frames().find(frame => frame.parentFrame() === runner);
    assert.ok(runner && content, 'Default route must start both runner and content frames');
    for (const frame of [runner, content]) {
      assert.equal(await frame.evaluate(() => self.origin), 'null', 'Every preview frame must remain opaque');
      assert.equal(await frame.evaluate(() => { try { void parent.document.body; return false; } catch { return true; } }), true, 'Parent DOM must be inaccessible');
    }
    await content.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 30000 });
    await content.locator('flt-semantics-placeholder').evaluate(e => e.click());
    if (process.argv[3]) {
      // Flutter copies through navigator.clipboard.writeText inside the opaque frame.
      await preview.evaluate(() => navigator.clipboard.writeText('clipboard sentinel'));
      const copy = content.getByRole('button', { name: 'Copy code', exact: true }).first();
      await copy.waitFor({ state: 'attached', timeout: 30000 });
      await copy.focus();
      await copy.press('Enter');
      let copied = 'clipboard sentinel';
      for (let attempt = 0; attempt < 20 && copied === 'clipboard sentinel'; attempt++) {
        await preview.waitForTimeout(250);
        copied = await preview.evaluate(() => navigator.clipboard.readText()).catch(() => 'clipboard sentinel');
      }
      assert.notEqual(copied, 'clipboard sentinel', 'Flutter copy must reach the system clipboard');
      const read = await content.evaluate(() => navigator.clipboard.readText().then(() => 'allowed', error => error.name));
      assert.equal(read, 'NotAllowedError', 'Previews may write but never read the clipboard');
    } else {
      await content.getByRole('button', { name: 'Increment counter' }).click();
      await content.getByText('Counter: 1', { exact: true }).waitFor();
    }
    assert.deepEqual(errors, [], 'Flutter startup must not produce uncaught errors');
    // A loaded site's own runtime errors stay in the console, like a normal website.
    await content.evaluate(() => { setTimeout(() => { throw new Error('late site failure'); }); Promise.reject(new Error('late rejection')); });
    await preview.waitForTimeout(1000);
    assert.equal(await preview.getByText('Unable to open preview').count(), 0, 'Errors after load must not replace a visible preview');
    assert.equal(await preview.locator('iframe.shown').count(), 1, 'The loaded preview must remain visible');
    await preview.screenshot({ path: '/tmp/club-same-host-preview.png' });
    // HTTP sandbox must also protect direct visits, without any iframe attribute.
    const direct = await context.newPage();
    await direct.goto(origin + '/site-runner/index.html#' + new URLSearchParams({parent: origin, session: 'direct'}));
    assert.equal(await direct.evaluate(() => self.origin), 'null', 'Direct runner navigation must enforce CSP sandbox');
    console.log('PASS: clipboard copy, late errors keep preview, Enable sites checkbox, disabled access, persistence, sidebar new tab, no runner config, HTTP CSP, opaque frames, Flutter interaction, direct navigation');
  } finally {
    try {
      if (settingsPage && originalDisabled !== undefined) {
        await settingsPage.goto(origin + '/admin/settings/sites');
        const checkbox = settingsPage.getByRole('checkbox', { name: /Enable sites/ });
        await checkbox.waitFor();
        if (await checkbox.isChecked() !== !originalDisabled) {
          await checkbox.setChecked(!originalDisabled);
          await settingsPage.getByRole('status').filter({ hasText: 'Saved.' }).waitFor();
        }
      }
    } finally { await browser.close(); }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
