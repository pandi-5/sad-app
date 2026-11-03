/* Avisa cuando este servidor deja de responder y ofrece el servidor de respaldo. */
(function () {
  "use strict";
  var bar = document.getElementById("failbar");
  if (!bar) return;
  var fails = 0;

  function check() {
    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, 2500);
    fetch("/healthz", { cache: "no-store", signal: ctrl.signal })
      .then(function (r) { if (!r.ok) throw new Error("estado " + r.status); fails = 0; })
      .catch(function () { fails += 1; })
      .finally(function () {
        clearTimeout(timer);
        bar.hidden = fails < 2;
      });
  }

  setInterval(check, 4000);
})();
