/* Actualiza la vista del clúster cada pocos segundos. */
(function () {
  "use strict";
  var box = document.getElementById("cluster-live");
  if (!box) return;
  var url = box.getAttribute("data-fragment-url");
  var dot = document.querySelector("[data-live-indicator]");
  var busy = false;

  function refresh() {
    if (busy || document.hidden) return;
    busy = true;
    fetch(url, { cache: "no-store", headers: { "X-Requested-With": "fetch" } })
      .then(function (r) { if (!r.ok) throw new Error("estado " + r.status); return r.text(); })
      .then(function (html) { box.innerHTML = html; if (dot) dot.classList.remove("is-off"); })
      .catch(function () { if (dot) dot.classList.add("is-off"); })
      .finally(function () { busy = false; });
  }

  setInterval(refresh, 3000);
})();
