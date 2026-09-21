const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {resolve} = require('node:path');
const {JSDOM} = require('jsdom');

const source = readFileSync(resolve(__dirname, '../../../mt-static/plugins/Jev/header_search.js'), 'utf8');
const markup = `<div class="mt-search-form">
  <div class="search-type">
    <input type="radio" name="type" value="entry" checked>
    <input type="radio" name="type" value="content_data">
    <input type="radio" name="type" value="asset">
  </div>
  <div class="search-content-type"><select><option value="42">Records</option></select></div>
  <div class="search-input-group">
    <div class="search-text-box"><input type="text"></div>
    <div class="submit-button"><button type="button"><span>Search</span></button></div>
  </div>
</div>`;

function setup(defaultOn = true) {
  const dom = new JSDOM(`<script data-jev-header data-default="${defaultOn ? 1 : 0}" data-label="Jev を使う"></script>
    <script data-script="admin-ui" data-blog-id="7" data-magic-token="test-token"></script>
    <div class="search-button-modal">${markup}</div>`, {runScripts: 'outside-only', url: 'https://mt.example.test/mt.cgi'});
  const {window} = dom;
  window.ScriptURI = '/mt.cgi';
  const submissions = [];
  window.HTMLFormElement.prototype.submit = function () {
    submissions.push({method: this.method, action: this.action, params: Object.fromEntries(new window.FormData(this))});
  };
  window.eval(source);
  const root = window.document.querySelector('.mt-search-form');
  const input = root.querySelector('input[type="text"]');
  const checkbox = root.querySelector('[name="is_jev"]');
  const button = root.querySelector('button');
  const changeType = value => {
    const radio = root.querySelector(`[value="${value}"]`);
    radio.checked = true;
    radio.dispatchEvent(new window.Event('change', {bubbles: true}));
  };
  const keydown = options => input.dispatchEvent(new window.KeyboardEvent('keydown', {bubbles: true, cancelable: true, key: 'Enter', ...options}));
  return {dom, window, root, input, checkbox, button, submissions, changeType, keydown};
}

test('checkbox below text input submits Jev once with all MT context', t => {
  const s = setup(); t.after(() => s.window.close());
  assert.equal(s.input.nextElementSibling, s.checkbox.parentElement);
  assert.equal(s.checkbox.parentElement.textContent, 'Jev を使う');
  assert.equal(s.checkbox.checked, true);
  let coreCalls = 0;
  s.button.addEventListener('click', () => coreCalls++);
  s.input.value = '  導入後に困った記事  ';
  s.button.querySelector('span').click();
  assert.equal(coreCalls, 0);
  assert.deepEqual(s.submissions, [{method: 'post', action: 'https://mt.example.test/mt.cgi', params: {
    __mode: 'search_replace', blog_id: '7', _type: 'entry', object_type: 'entry',
    do_search: '1', magic_token: 'test-token', search: '導入後に困った記事',
    content_type_id: '42', is_jev: '1',
  }}]);
});

test('Enter submits Jev; IME confirmation does not', t => {
  const s = setup(); t.after(() => s.window.close());
  s.keydown({isComposing: true});
  assert.equal(s.submissions.length, 0);
  s.keydown();
  assert.equal(s.submissions.length, 1);
});

test('OFF default and manually unchecked searches preserve core handlers', t => {
  for (const defaultOn of [true, false]) {
    const s = setup(defaultOn); t.after(() => s.window.close());
    assert.equal(s.checkbox.checked, defaultOn);
    if (defaultOn) s.checkbox.click();
    let coreCalls = 0;
    s.button.addEventListener('click', () => coreCalls++);
    s.input.addEventListener('keydown', () => coreCalls++);
    s.button.click(); s.keydown();
    assert.equal(coreCalls, 2);
    assert.equal(s.submissions.length, 0);
    s.checkbox.click(); s.button.click();
    assert.equal(s.submissions[0].params.is_jev, '1');
  }
});

test('unsupported targets use core search and switching back restores preference', t => {
  const s = setup(); t.after(() => s.window.close());
  s.changeType('asset');
  assert.equal(s.checkbox.disabled, true);
  assert.equal(s.checkbox.checked, false);
  let coreCalls = 0;
  s.button.addEventListener('click', () => coreCalls++);
  s.button.click();
  assert.equal(coreCalls, 1);
  assert.equal(s.submissions.length, 0);
  s.changeType('content_data');
  assert.equal(s.checkbox.disabled, false);
  assert.equal(s.checkbox.checked, true);
  s.button.click();
  assert.equal(s.submissions[0].params._type, 'content_data');
  assert.equal(s.submissions[0].params.content_type_id, '42');
});

test('dynamic popup and mobile forms receive the same choice without duplicates', async t => {
  const s = setup(); t.after(() => s.window.close());
  s.checkbox.click();
  s.window.document.querySelector('.search-button-modal').remove();
  const mobile = s.window.document.createElement('div');
  mobile.dataset.is = 'search-form';
  mobile.innerHTML = markup;
  s.window.document.body.append(mobile);
  await new Promise(resolve => s.window.setTimeout(resolve, 0));
  assert.equal(mobile.querySelectorAll('[name="is_jev"]').length, 1);
  assert.equal(mobile.querySelector('[name="is_jev"]').checked, false);
  mobile.querySelector('.search-content-type').append(s.window.document.createElement('span'));
  await new Promise(resolve => s.window.setTimeout(resolve, 0));
  assert.equal(mobile.querySelectorAll('[name="is_jev"]').length, 1);
  mobile.querySelector('[name="is_jev"]').click();
  mobile.querySelector('button').click();
  assert.equal(s.submissions[0].params.is_jev, '1');
});

test('legacy form includes checked is_jev and omits it when unchecked', async t => {
  const s = setup(); t.after(() => s.window.close());
  const legacy = s.window.document.createElement('form');
  legacy.id = 'basic-search';
  legacy.innerHTML = '<input name="_type" value="page" type="hidden"><input name="search" type="text">';
  s.window.document.body.append(legacy);
  await new Promise(resolve => s.window.setTimeout(resolve, 0));
  assert.equal(new s.window.FormData(legacy).get('is_jev'), '1');
  legacy.querySelector('[name="is_jev"]').click();
  assert.equal(new s.window.FormData(legacy).has('is_jev'), false);
});

test('unrelated text inputs and search results form remain untouched', async t => {
  const s = setup(); t.after(() => s.window.close());
  const unrelated = s.window.document.createElement('form');
  unrelated.id = 'search-form';
  unrelated.innerHTML = '<input type="text" name="search"><input type="checkbox" id="is_jev">';
  s.window.document.body.append(unrelated);
  await new Promise(resolve => s.window.setTimeout(resolve, 0));
  assert.equal(unrelated.querySelectorAll('input').length, 2);
  assert.equal(unrelated.querySelector('.jev-header-option'), null);
});
