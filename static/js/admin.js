(function () {
  "use strict";

  var shell = document.querySelector("[data-admin]");
  if (!shell) return;

  var html = document.documentElement;
  html.classList.add("js-tabs");

  var buttons = Array.prototype.slice.call(shell.querySelectorAll("[data-tab-button]"));
  var panels = Array.prototype.slice.call(shell.querySelectorAll("[data-tab-panel]"));

  function normalize(name) {
    if (!name) return "";
    return name.replace(/^#/, "").replace(/^tab-/, "");
  }

  function activate(name) {
    var target = normalize(name) || "general";
    if (!panels.some(function (panel) { return panel.getAttribute("data-tab-panel") === target; })) {
      target = "general";
    }
    buttons.forEach(function (button) {
      var active = button.getAttribute("data-tab-button") === target;
      button.classList.toggle("is-active", active);
      button.setAttribute("aria-selected", active ? "true" : "false");
    });
    panels.forEach(function (panel) {
      var active = panel.getAttribute("data-tab-panel") === target;
      panel.classList.toggle("is-active", active);
      if (active) panel.removeAttribute("hidden");
      else panel.setAttribute("hidden", "");
    });
  }

  buttons.forEach(function (button) {
    button.addEventListener("click", function () {
      var name = button.getAttribute("data-tab-button");
      activate(name);
      try { history.replaceState(null, "", "#" + name); } catch (error) { /* nada */ }
    });
  });

  window.addEventListener("hashchange", function () {
    activate(window.location.hash);
  });

  var initial = shell.getAttribute("data-initial-tab") || window.location.hash;
  activate(initial);

  // ---------------------------------------------------------------- estado en vivo
  function formatSize(bytes) {
    if (!bytes) return "0 B";
    var units = ["B", "KB", "MB", "GB", "TB"];
    var index = 0;
    var value = bytes;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    return (index === 0 ? value : value.toFixed(1)) + " " + units[index];
  }

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function icon(name) {
    return '<svg class="icon" aria-hidden="true"><use href="/static/icons.svg#' + name + '"></use></svg>';
  }

  function updateStats(stats) {
    document.querySelectorAll("[data-stat]").forEach(function (element) {
      var key = element.getAttribute("data-stat");
      if (key === "online") {
        element.innerHTML = stats.online + "<small>/" + stats.users + "</small>";
      } else if (key === "bytes") {
        element.textContent = formatSize(stats.bytes);
      } else if (stats[key] !== undefined) {
        element.textContent = stats[key];
      }
    });
  }

  function updateUsers(users) {
    users.forEach(function (user) {
      var selector = '[data-user-online="' + CSS.escape(user.name) + '"]';
      var presence = document.querySelector(selector);
      if (presence) {
        presence.classList.toggle("is-online", !!user.online);
        presence.classList.toggle("is-offline", !user.online);
        var text = presence.querySelector(".presence__text");
        if (text) text.textContent = user.online ? "conectado" : "desconectado";
      }
      var seen = document.querySelector('[data-user-seen="' + CSS.escape(user.name) + '"]');
      if (seen) {
        seen.setAttribute("data-seen", user.seen || 0);
        seen.textContent = user.seen && window.SAD ? window.SAD.relative(user.seen) : "nunca";
      }
      var ip = document.querySelector('[data-user-ip="' + CSS.escape(user.name) + '"]');
      if (ip) ip.textContent = user.ip || "—";
    });
  }

  function updateFiles(files) {
    files.forEach(function (file) {
      var cell = document.querySelector('[data-file-lock="' + CSS.escape(file.id) + '"]');
      if (!cell) return;
      if (file.owner) {
        cell.innerHTML = '<span class="badge badge--lock">' + icon("lock") + " " +
          escapeHtml(file.owner) +
          (file.remaining ? '<span data-lock-remaining="' + file.remaining + '">' + file.remaining + "s</span>" : "") +
          "</span>";
      } else {
        cell.innerHTML = '<span class="badge badge--ok">' + icon("unlock") + " libre</span>";
      }
    });
  }

  var polling = false;
  function poll() {
    if (polling || document.hidden) return;
    polling = true;
    fetch("/admin/status", {
      headers: { "X-Requested-With": "XMLHttpRequest", "Accept": "application/json" },
    })
      .then(function (response) {
        if (!response.ok) throw new Error("status");
        return response.json();
      })
      .then(function (data) {
        updateStats(data.stats);
        updateUsers(data.users);
        updateFiles(data.files);
        var live = document.querySelector("[data-live-indicator]");
        if (live) live.title = "Actualizado " + (window.SAD ? window.SAD.relative(data.now) : "ahora");
      })
      .catch(function () {
        var live = document.querySelector("[data-live-indicator]");
        if (live) live.title = "Sin conexión con el servidor";
      })
      .finally(function () { polling = false; });
  }

  window.setInterval(poll, 5000);
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) poll();
  });
  window.setTimeout(poll, 1500);
})();
