(function () {
  "use strict";

  var html = document.documentElement;

  function csrfToken() {
    var meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.getAttribute("content") : "";
  }

  function setTheme(theme) {
    html.setAttribute("data-theme", theme);
    try { localStorage.setItem("sad:theme", theme); } catch (error) { /* sin almacenamiento */ }
  }

  function currentTheme() {
    return html.getAttribute("data-theme") === "dark" ? "dark" : "light";
  }

  // Tema claro / oscuro
  document.querySelectorAll("[data-theme-toggle]").forEach(function (button) {
    button.addEventListener("click", function () {
      setTheme(currentTheme() === "dark" ? "light" : "dark");
    });
  });

  // Mostrar / ocultar contraseña
  document.querySelectorAll("[data-password-toggle]").forEach(function (button) {
    button.addEventListener("click", function () {
      var field = button.closest(".password-field");
      var input = field && field.querySelector("input");
      if (!input) return;
      var show = input.type === "password";
      input.type = show ? "text" : "password";
      button.setAttribute("aria-label", show ? "Ocultar contraseña" : "Mostrar contraseña");
      var use = button.querySelector("use");
      if (use) {
        use.setAttribute("href", "/static/icons.svg#" + (show ? "eye-off" : "eye"));
      }
    });
  });

  // Confirmaciones para acciones destructivas
  document.querySelectorAll("form[data-confirm]").forEach(function (form) {
    form.addEventListener("submit", function (event) {
      var message = form.getAttribute("data-confirm") || "¿Continuar?";
      if (!window.confirm(message)) {
        event.preventDefault();
      }
    });
  });

  // Envío automático de formularios (permisos, modo, etc.)
  document.querySelectorAll("form[data-autosubmit]").forEach(function (form) {
    var timer = null;
    form.querySelectorAll("[data-autosubmit-input]").forEach(function (input) {
      input.addEventListener("change", function () {
        if (input.type === "radio") {
          form.querySelectorAll(".mode-card").forEach(function (card) {
            card.classList.remove("is-selected");
          });
          var card = input.closest(".mode-card");
          if (card) card.classList.add("is-selected");
        }
        window.clearTimeout(timer);
        timer = window.setTimeout(function () {
          if (form.requestSubmit) {
            form.requestSubmit();
          } else {
            form.submit();
          }
        }, 120);
      });
    });
  });

  // Avisos flotantes
  document.querySelectorAll("[data-toast]").forEach(function (toast) {
    var close = toast.querySelector("[data-toast-close]");
    var remove = function () {
      toast.style.opacity = "0";
      toast.style.transform = "translateY(-4px)";
      window.setTimeout(function () { toast.remove(); }, 160);
    };
    if (close) close.addEventListener("click", remove);
    window.setTimeout(remove, 7000);
  });

  // Cerrar menús al hacer clic fuera
  document.addEventListener("click", function (event) {
    document.querySelectorAll("details.menu[open]").forEach(function (menu) {
      if (!menu.contains(event.target)) menu.removeAttribute("open");
    });
  });

  // Cuentas atrás de bloqueos. Solo se actualizan nodos de texto: nunca
  // contenedores como el editor, que también llevan atributos de datos.
  var lockElements = Array.prototype.slice
    .call(document.querySelectorAll("[data-lock-remaining]"))
    .filter(function (element) {
      return element.children.length === 0;
    });
  if (lockElements.length) {
    var tick = function () {
      lockElements.forEach(function (element) {
        var value = parseInt(element.getAttribute("data-lock-remaining"), 10);
        if (isNaN(value)) return;
        value = Math.max(0, value - 1);
        element.setAttribute("data-lock-remaining", String(value));
        if (value > 0) {
          element.textContent = value + "s";
        } else {
          element.textContent = "caducado";
        }
      });
    };
    window.setInterval(tick, 1000);
  }

  // Fechas relativas (solo presentación)
  function relative(ts) {
    var seconds = Math.max(0, Math.floor(Date.now() / 1000 - ts));
    if (seconds < 60) return "hace " + seconds + " s";
    if (seconds < 3600) return "hace " + Math.floor(seconds / 60) + " min";
    if (seconds < 86400) return "hace " + Math.floor(seconds / 3600) + " h";
    return "hace " + Math.floor(seconds / 86400) + " d";
  }
  document.querySelectorAll("[data-seen]").forEach(function (element) {
    var value = parseFloat(element.getAttribute("data-seen"));
    if (!isNaN(value) && value > 0) element.textContent = relative(value);
  });

  // Utilidades expuestas para otras vistas
  window.SAD = {
    csrfToken: csrfToken,
    setTheme: setTheme,
    currentTheme: currentTheme,
    relative: relative,
  };
})();
