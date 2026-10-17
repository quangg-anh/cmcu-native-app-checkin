// Offline regression for JavaScript actually shipped inside PortalWebClient.
// Run: node --test tool/verify_portal_bridge.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const dart = fs.readFileSync(
  path.join(__dirname, '../lib/core/portal_web_client.dart'),
  'utf8',
);
const source = dart.match(/const _postInPortal = r'''\r?\n([\s\S]*?)\r?\n''';/)[1];
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction(
  'origin', 'allowedPaths', 'url', 'body', 'userId',
  'location', 'edu', 'XMLHttpRequest', source,
);
const origin = 'https://iu.cmcu.edu.vn';
const apiPath = '/sinhvienapi/api/SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv';
const url = origin + apiPath;

function setup(options = {}) {
  const calls = [];
  class XHR {
    constructor() { calls.push(this); this.headers = {}; }
    open(method, target, async) {
      Object.assign(this, { method, target, async });
    }
    setRequestHeader(name, value) { this.headers[name] = value; }
    send(body) {
      this.body = body;
      this.status = options.status ?? 200;
      this.responseText = options.responseText ?? '{"Success":true,"Data":[]}';
      this.responseURL = options.responseURL ?? url;
      if (options.event) this[options.event]();
      else this.onload();
    }
  }
  return {
    calls,
    run: () => run(
      origin, [apiPath], options.url ?? url, 'A=encoded%2Bform&keyword=%26',
      'synthetic-student',
      { origin: options.origin ?? origin },
      options.edu ?? { system: { userId: 'synthetic-student', tokenJWT: 'fresh-portal-token' } },
      XHR,
    ),
  };
}

test('XHR sends unchanged form; browser owns cookies, UA, Origin, Referer', async () => {
  const s = setup();
  assert.deepEqual(await s.run(), { status: 200, body: '{"Success":true,"Data":[]}' });
  assert.equal(s.calls.length, 1);
  const request = s.calls[0];
  assert.equal(request.method, 'POST');
  assert.equal(request.target, url);
  assert.equal(request.async, true);
  assert.equal(request.withCredentials, true);
  assert.equal(request.timeout, 30000);
  assert.equal(request.body, 'A=encoded%2Bform&keyword=%26');
  assert.deepEqual(request.headers, {
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    Accept: 'application/json, text/javascript, */*; q=0.01',
    'X-Requested-With': 'XMLHttpRequest',
    Authorization: 'Bearer fresh-portal-token',
  });
});

test('cookie-authenticated portal context need not provide JWT', async () => {
  const s = setup({ edu: { system: { userId: 'synthetic-student' } } });
  assert.equal((await s.run()).status, 200);
  assert.equal('Authorization' in s.calls[0].headers, false);
});

for (const options of [
  { origin: 'https://login.microsoftonline.com' },
  { edu: {} },
  { edu: { system: { userId: 'different-account', tokenJWT: 'other-token' } } },
]) {
  test(`wrong page/account cannot send request: ${JSON.stringify(options)}`, async () => {
    const s = setup(options);
    assert.deepEqual(await s.run(), { expired: true });
    assert.equal(s.calls.length, 0);
  });
}

for (const target of [
  'https://example.test' + apiPath,
  origin + '/congthongtin/login.aspx',
  url + '?query=true',
  url + '#fragment',
  'https://user:password@iu.cmcu.edu.vn' + apiPath,
]) {
  test(`JS rechecks request allowlist: ${target}`, async () => {
    const s = setup({ url: target });
    assert.deepEqual(await s.run(), { failed: true });
    assert.equal(s.calls.length, 0);
  });
}

for (const responseURL of [
  origin + '/congthongtin/login.aspx',
  origin + '/congthongtin/LOGIN.aspx?expired=1',
  'https://login.microsoftonline.com/synthetic',
]) {
  test(`login redirect expires session: ${responseURL}`, async () => {
    const s = setup({ responseURL });
    assert.deepEqual(await s.run(), { expired: true });
    assert.equal(s.calls.length, 1);
  });
}

for (const event of ['onerror', 'ontimeout', 'onabort']) {
  test(`XHR ${event} gives safe error without replay`, async () => {
    const s = setup({ event });
    assert.deepEqual(await s.run(), { failed: true });
    assert.equal(s.calls.length, 1);
  });
}

test('401 passes through once; no unauthenticated retry', async () => {
  const s = setup({ status: 401, responseText: 'synthetic error' });
  assert.deepEqual(await s.run(), { status: 401, body: 'synthetic error' });
  assert.equal(s.calls.length, 1);
});
