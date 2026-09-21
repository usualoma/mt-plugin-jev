const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const {JSDOM} = require('jsdom');
const source = name => readFileSync(resolve(__dirname, `../../../mt-static/plugins/Jev/${name}.js`), 'utf8');

test('natural search disables fields and restores the original controls', t => {
  const dom = new JSDOM(`<form>
    <input id="is_jev" type="checkbox">
    <input id="case" type="checkbox" checked>
    <input id="is_regex" type="checkbox" disabled>
    <input id="is_limited" type="checkbox" checked>
    <div id="limited-fields"><input name="search_cols" value="title" checked type="checkbox"><input name="search_cols" value="hidden" disabled type="checkbox"></div>
    <input name="search-replace-toggle" value="search" type="radio">
    <input name="search-replace-toggle" value="replace" type="radio">
    <input name="do_replace" value="1"><button id="replace-button"></button>
    <div id="search-bar-replace-fields"></div><span id="jev-search-hint" hidden></span>
  </form>`, {runScripts: 'outside-only'});
  t.after(() => dom.window.close());
  const {window} = dom, d = window.document;
  window.eval(source('search'));
  d.querySelector('#is_jev').click();
  for (const id of ['case', 'is_regex', 'is_limited']) {
    assert.equal(d.getElementById(id).disabled, true);
    assert.equal(d.getElementById(id).checked, false);
  }
  assert.equal(d.getElementById('limited-fields').style.display, 'none');
  assert.equal(d.querySelector('[name=search_cols]').disabled, true);
  assert.equal(d.getElementById('jev-search-hint').hidden, false);
  d.querySelector('form').dispatchEvent(new window.Event('submit'));
  assert.equal(d.querySelector('[name=do_replace]').value, '0');
  d.getElementById('is_jev').click();
  assert.equal(d.getElementById('case').checked, true);
  assert.equal(d.getElementById('case').disabled, false);
  assert.equal(d.getElementById('is_regex').disabled, true);
  assert.equal(d.getElementById('is_limited').checked, true);
  assert.equal(d.getElementById('limited-fields').style.display, '');
  assert.equal(d.querySelector('[name=search_cols]').disabled, false);
  assert.equal(d.querySelector('[value=hidden]').disabled, true);
});

test('API key editors are independent and blank means an explicit deletion', t => {
  const dom = new JSDOM(`<form>${['jev', 'openai'].map(p => `
    <div id="${p}-saved-key">********1234<button id="${p}-update-key" type="button">Update</button></div>
    <input id="${p}_api_key" name="${p}_api_key" type="password" hidden disabled>`).join('')}</form>`, {runScripts: 'outside-only'});
  t.after(() => dom.window.close());
  const {window} = dom, d = window.document;
  window.eval(source('system_config'));
  assert.equal(new window.FormData(d.querySelector('form')).has('openai_api_key'), false);
  d.getElementById('openai-update-key').click();
  assert.equal(d.getElementById('openai_api_key').disabled, false);
  assert.equal(d.getElementById('openai_api_key').hidden, false);
  assert.equal(d.getElementById('jev_api_key').disabled, true);
  assert.equal(new window.FormData(d.querySelector('form')).get('openai_api_key'), '');
});
