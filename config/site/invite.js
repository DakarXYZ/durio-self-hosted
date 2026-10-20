// Invite page (/invite/<code>, the standard server invite links): shows the server address and the code, copy buttons.
// Served under CSP script-src 'self': no inline code, no third-party scripts, text only via textContent.
"use strict";

document.addEventListener("DOMContentLoaded", function () {
  var match = /^\/invite\/([A-Za-z0-9_-]{1,128})\/?$/.exec(location.pathname);
  var values = {
    server: location.host,
    code: match ? match[1] : "",
    link: match ? location.origin + "/invite/" + match[1] : ""
  };

  function each(selector, fn) {
    Array.prototype.forEach.call(document.querySelectorAll(selector), fn);
  }

  if (!values.code) {
    each("[data-missing]", function (el) { el.hidden = false; });
    return;
  }

  each("[data-server]", function (el) { el.textContent = values.server; });
  each("[data-code]", function (el) { el.textContent = values.code; });
  each("[data-invite]", function (el) { el.hidden = false; });

  // Fallback for browsers without the async clipboard API (or outside a secure context)
  function copyBySelection(text) {
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    document.body.removeChild(area);
    return ok ? Promise.resolve() : Promise.reject(new Error("copy failed"));
  }

  function copy(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () { return copyBySelection(text); });
    }
    return copyBySelection(text);
  }

  each("[data-copy]", function (button) {
    var label = button.textContent;
    button.addEventListener("click", function () {
      copy(values[button.getAttribute("data-copy")]).then(function () {
        button.textContent = button.getAttribute("data-done");
        setTimeout(function () { button.textContent = label; }, 2000);
      }, function () {});
    });
  });
});
