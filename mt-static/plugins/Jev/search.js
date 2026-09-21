(() => {
  "use strict";
  const checkbox = document.getElementById("is_jev");
  if (!checkbox) return;
  const form = checkbox.form;
  const controls = ["case", "is_regex", "is_limited"].map((id) => document.getElementById(id)).filter(Boolean);
  const replace = document.getElementById("search-bar-replace-fields");
  const replaceButton = document.getElementById("replace-button");
  const hint = document.getElementById("jev-search-hint");
  const fields = Array.from(form.querySelectorAll('[name="search_cols"]'));
  const disabled = new Map([...controls, ...fields].map(control => [control, control.disabled]));
  const limited = document.getElementById("limited-fields");
  const previous = new Map(controls.map((control) => [control, control.checked]));
  const update = () => {
    for (const control of controls) {
      if (checkbox.checked && !control.disabled) previous.set(control, control.checked);
      control.checked = checkbox.checked ? false : previous.get(control);
      control.disabled = checkbox.checked || disabled.get(control);
    }
    for (const field of fields) field.disabled = checkbox.checked || disabled.get(field);
    if (limited) limited.style.display = !checkbox.checked && document.getElementById("is_limited")?.checked ? "" : "none";
    // Also cover the initial normal-search form before its next submission.
    for (const control of form.querySelectorAll('input[name="search-replace-toggle"]')) {
      if (control.value === "replace") control.disabled = checkbox.checked;
      if (checkbox.checked && control.value === "search") control.checked = true;
    }
    if (replaceButton) replaceButton.disabled = checkbox.checked;
    if (replace && checkbox.checked) replace.style.display = "none";
    if (hint) hint.hidden = !checkbox.checked;
  };
  checkbox.addEventListener("change", update);
  form.addEventListener("submit", () => {
    if (checkbox.checked) {
      const doReplace = form.elements.namedItem("do_replace");
      if (doReplace) doReplace.value = "0";
    }
  });
  update();
})();
