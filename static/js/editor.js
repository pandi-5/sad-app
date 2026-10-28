(function () {
  "use strict";

  var root = document.querySelector("[data-editor]");
  if (!root) return;

  var textarea = root.querySelector("[data-editor-text]");
  var form = root.querySelector("[data-editor-form]");
  var versionInput = root.querySelector("[data-version-input]");
  var saveButton = root.querySelector("[data-save-button]");
  var state = root.querySelector("[data-editor-state]");
  var counter = root.querySelector("[data-editor-count]");
  var draftBanner = root.querySelector("[data-draft-banner]");
  var draftRestore = root.querySelector("[data-draft-restore]");
  var draftDiscard = root.querySelector("[data-draft-discard]");
  var heartbeatState = root.querySelector("[data-heartbeat-state]");
  var countdown = root.querySelector("[data-lock-countdown]");
  var mode = root.getAttribute("data-mode") || "libre";
  var canEdit = root.getAttribute("data-can-edit") === "1";
  var draftKey = root.getAttribute("data-draft-key") || "";
  var heartbeatUrl = root.getAttribute("data-heartbeat-url");
  var statusUrl = root.getAttribute("data-status-url");
  var initialVersion = parseInt(root.getAttribute("data-version"), 10) || 0;
  var remaining = parseInt(root.getAttribute("data-lock-initial"), 10) || 0;
  var initialValue = textarea ? textarea.value : "";
  var dirty = false;
  var draftTimer = null;
  var remoteAlertShown = false;

  function csrfToken() {
    return window.SAD ? window.SAD.csrfToken() : "";
  }

  function setState(text, className) {
    if (!state) return;
    state.textContent = text;
    state.className = className || "";
  }

  function updateCounter() {
    if (!counter || !textarea) return;
    var count = textarea.value.length;
    counter.textContent = count.toLocaleString("es") + " caracteres";
  }

  function markDirty() {
    if (!textarea || !canEdit) return;
    dirty = textarea.value !== initialValue;
    if (dirty) {
      setState("Cambios sin guardar", "is-dirty");
      scheduleDraft();
    } else {
      setState("Sin cambios", "is-saved");
      removeDraft();
    }
  }

  function scheduleDraft() {
    if (!draftKey) return;
    window.clearTimeout(draftTimer);
    draftTimer = window.setTimeout(function () {
      try { localStorage.setItem(draftKey, textarea.value); } catch (error) { /* sin espacio */ }
    }, 450);
  }

  function removeDraft() {
    if (!draftKey) return;
    try { localStorage.removeItem(draftKey); } catch (error) { /* nada */ }
  }

  function loadDraft() {
    if (!draftKey || !draftBanner || !textarea) return;
    var stored = null;
    try { stored = localStorage.getItem(draftKey); } catch (error) { return; }
    if (stored !== null && stored !== textarea.value) {
      draftBanner.hidden = false;
    }
  }

  if (textarea) {
    textarea.addEventListener("input", function () {
      updateCounter();
      markDirty();
    });
    textarea.addEventListener("keydown", function (event) {
      if (event.key === "Tab") {
        event.preventDefault();
        var start = textarea.selectionStart;
        var end = textarea.selectionEnd;
        textarea.value = textarea.value.slice(0, start) + "\t" + textarea.value.slice(end);
        textarea.selectionStart = textarea.selectionEnd = start + 1;
        updateCounter();
        markDirty();
        return;
      }
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        if (canEdit && form) {
          if (form.requestSubmit) form.requestSubmit();
          else form.submit();
        }
      }
    });
  }

  // Cualquier formulario de la página (guardar, copia, restaurar, salir)
  // descarta el borrador local y evita el aviso de cambios sin guardar.
  document.querySelectorAll("form").forEach(function (pageForm) {
    pageForm.addEventListener("submit", function () {
      removeDraft();
      dirty = false;
    });
  });

  if (draftRestore && textarea) {
    draftRestore.addEventListener("click", function () {
      var stored = null;
      try { stored = localStorage.getItem(draftKey); } catch (error) { stored = null; }
      if (stored !== null) {
        textarea.value = stored;
        updateCounter();
        markDirty();
        textarea.focus();
      }
      if (draftBanner) draftBanner.hidden = true;
    });
  }

  if (draftDiscard) {
    draftDiscard.addEventListener("click", function () {
      removeDraft();
      if (draftBanner) draftBanner.hidden = true;
    });
  }

  window.addEventListener("beforeunload", function (event) {
    if (dirty && canEdit) {
      event.preventDefault();
      event.returnValue = "";
    }
  });

  window.setTimeout(loadDraft, 50);
  updateCounter();

  function updateLockDisplay(value) {
    remaining = Math.max(0, parseInt(value, 10) || 0);
    document.querySelectorAll("[data-lock-remaining]").forEach(function (element) {
      // Evita tocar contenedores; solo actualiza los nodos que muestran el reloj.
      if (element.children.length > 0) return;
      element.setAttribute("data-lock-remaining", String(remaining));
      element.textContent = remaining > 0 ? remaining + "s" : "caducado";
    });
    if (countdown) countdown.textContent = remaining > 0 ? remaining + "s" : "caducado";
  }

  if (countdown) {
    window.setInterval(function () {
      if (remaining > 0) {
        remaining -= 1;
        countdown.textContent = remaining > 0 ? remaining + "s" : "caducado";
      }
    }, 1000);
  }

  function heartbeat() {
    if (mode !== "bloqueo" || !canEdit || !heartbeatUrl) return;
    fetch(heartbeatUrl, {
      method: "POST",
      headers: {
        "X-Requested-With": "XMLHttpRequest",
        "X-CSRFToken": csrfToken(),
      },
    })
      .then(function (response) {
        return response.json().then(function (data) {
          return { status: response.status, data: data };
        });
      })
      .then(function (result) {
        var data = result.data || {};
        if (result.status === 200 && data.ok) {
          updateLockDisplay(data.remaining);
          if (heartbeatState) {
            heartbeatState.textContent = "Bloqueo renovado automáticamente.";
            heartbeatState.className = "hint is-saved";
          }
          if (data.ver && data.ver !== initialVersion) {
            showRemoteChange(data.ver, data.author);
          }
        } else {
          if (heartbeatState) {
            heartbeatState.textContent = "Perdiste el bloqueo o caducó. Vuelve a abrir el archivo.";
            heartbeatState.className = "hint is-dirty";
          }
          if (textarea) textarea.readOnly = true;
          if (saveButton) saveButton.disabled = true;
        }
      })
      .catch(function () {
        if (heartbeatState) heartbeatState.textContent = "No se pudo renovar el bloqueo (sin conexión).";
      });
  }

  function showRemoteChange(ver, author) {
    if (remoteAlertShown) return;
    remoteAlertShown = true;
    var alert = document.createElement("div");
    alert.className = "alert alert--warning";
    alert.setAttribute("role", "status");
    alert.appendChild(document.createTextNode(
      "Hay una versión más reciente en el servidor: v" + ver +
      (author ? " guardada por " + author : "") +
      ". Si guardas ahora, se aplicará el control de concurrencia. "
    ));
    var link = document.createElement("a");
    link.href = window.location.pathname;
    link.textContent = "Recargar el archivo";
    alert.appendChild(link);
    var editorCard = root.querySelector(".editor-card");
    if (editorCard && editorCard.parentNode) {
      editorCard.parentNode.insertBefore(alert, editorCard);
    }
  }

  function pollStatus() {
    if (!statusUrl) return;
    fetch(statusUrl, { headers: { "X-Requested-With": "XMLHttpRequest" } })
      .then(function (response) { return response.json(); })
      .then(function (data) {
        if (data.ver && data.ver !== initialVersion) {
          showRemoteChange(data.ver, data.author);
        }
        if (mode === "bloqueo" && data.remaining !== undefined) {
          updateLockDisplay(data.remaining);
        }
        if (data.can_edit === false && canEdit) {
          canEdit = false;
          if (textarea) textarea.readOnly = true;
          if (saveButton) saveButton.disabled = true;
          if (heartbeatState) {
            heartbeatState.textContent = "El archivo está bloqueado por otro usuario.";
            heartbeatState.className = "hint is-dirty";
          }
        }
      })
      .catch(function () { /* silencioso */ });
  }

  if (mode === "bloqueo" && canEdit) {
    window.setTimeout(heartbeat, 4000);
    window.setInterval(heartbeat, 30000);
  }
  if (statusUrl) {
    window.setInterval(pollStatus, 20000);
  }
})();
