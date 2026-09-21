(() => {
  "use strict";
  for (const provider of ["jev", "openai"]) {
    const button = document.getElementById(`${provider}-update-key`);
    if (!button) continue;
    button.addEventListener("click", () => {
      document.getElementById(`${provider}-saved-key`).remove();
      const input = document.getElementById(`${provider}_api_key`);
      input.hidden = false;
      input.disabled = false;
      input.focus();
    });
  }
})();
