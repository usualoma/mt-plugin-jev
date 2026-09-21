(function () {
  'use strict';

  const script = document.querySelector('script[data-jev-header]');
  if (!script) return;
  let preferred = script.dataset.default === '1';
  const selector = '.search-button-modal .mt-search-form, [data-is="search-form"] .mt-search-form, #basic-search';
  const forms = new WeakMap();
  const supported = type => ['entry', 'page', 'content_data'].includes(type);

  function mount(root) {
    if (forms.has(root)) {
      forms.get(root)();
      return;
    }
    const legacy = root.id === 'basic-search';
    const text = root.querySelector(legacy ? 'input[name="search"]' : '.search-text-box input[type="text"]');
    const context = document.querySelector('[data-script="admin-ui"]');
    if (!text || (!legacy && (!context || !window.ScriptURI))) return;

    const type = () => root.querySelector(legacy ? '[name="_type"]' : '.search-type input:checked')?.value;
    const label = document.createElement('label');
    label.className = 'jev-header-option';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.name = 'is_jev';
    checkbox.value = '1';
    label.append(checkbox, document.createTextNode(script.dataset.label));
    text.after(label);
    root.classList.add('jev-header-search');

    const sync = () => {
      checkbox.disabled = !supported(type());
      checkbox.checked = !checkbox.disabled && preferred;
    };
    forms.set(root, sync);
    sync();
    root.addEventListener('change', event => {
      if (event.target === checkbox && !checkbox.disabled) preferred = checkbox.checked;
      document.querySelectorAll(selector).forEach(form => forms.get(form)?.());
    });

    // Legacy header forms already submit named controls, including this checkbox.
    if (legacy) return;

    // MT 9's Svelte SearchForm creates a separate form and calls submit() directly.
    // Handle only Jev searches here; unchecked searches keep MT's original handler.
    function submit(event) {
      if (!checkbox.checked || checkbox.disabled || !supported(type())) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      const form = document.createElement('form');
      form.method = 'POST';
      form.action = window.ScriptURI;
      const params = {
        __mode: 'search_replace',
        blog_id: context.dataset.blogId || '',
        _type: type(),
        do_search: '1',
        magic_token: context.dataset.magicToken || '',
        search: text.value.trim(),
        content_type_id: root.querySelector('.search-content-type select')?.value || '',
        object_type: type(),
        is_jev: '1',
      };
      Object.entries(params).forEach(([name, value]) => {
        const input = document.createElement('input');
        input.type = 'hidden';
        input.name = name;
        input.value = value;
        form.append(input);
      });
      document.body.append(form);
      form.submit();
    }
    root.addEventListener('click', event => {
      if (event.target.closest('.submit-button button')) submit(event);
    }, true);
    root.addEventListener('keydown', event => {
      if (event.target === text && event.key === 'Enter' && !event.isComposing) submit(event);
    }, true);
  }

  function scan(node) {
    if (!(node instanceof Element)) return;
    const root = node.closest(selector);
    if (root) mount(root);
    node.querySelectorAll(selector).forEach(mount);
  }
  scan(document.body);
  // Both the desktop popup and mobile search are mounted after the page loads.
  new MutationObserver(records => {
    records.forEach(record => record.addedNodes.forEach(scan));
  }).observe(document.body, {childList: true, subtree: true});
}());
