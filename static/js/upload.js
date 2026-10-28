(function () {
  "use strict";

  var form = document.querySelector("[data-upload-form]");
  if (!form) return;

  var input = form.querySelector("[data-file-input]");
  var dropzone = form.querySelector("[data-dropzone]");
  var selection = form.querySelector("[data-upload-selection]");
  var progress = form.querySelector("[data-upload-progress]");
  var bar = form.querySelector("[data-upload-bar]");
  var label = form.querySelector("[data-upload-label]");
  var errorsBox = form.querySelector("[data-upload-errors]");
  var submit = form.querySelector("[data-upload-submit]");
  var maxBytes = parseInt(form.getAttribute("data-max-bytes"), 10) || 0;
  var uploading = false;

  function formatSize(bytes) {
    if (!bytes) return "0 B";
    var units = ["B", "KB", "MB", "GB"];
    var index = 0;
    var value = bytes;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    return (index === 0 ? value : value.toFixed(1)) + " " + units[index];
  }

  function showErrors(messages) {
    if (!errorsBox) return;
    errorsBox.innerHTML = "";
    if (!messages || !messages.length) {
      errorsBox.hidden = true;
      return;
    }
    var list = document.createElement("ul");
    list.className = "alert__list";
    messages.forEach(function (message) {
      var item = document.createElement("li");
      item.textContent = message;
      list.appendChild(item);
    });
    errorsBox.appendChild(list);
    errorsBox.hidden = false;
  }

  function selectedFiles() {
    return input && input.files ? Array.prototype.slice.call(input.files) : [];
  }

  function renderSelection() {
    if (!selection) return;
    selection.innerHTML = "";
    var files = selectedFiles();
    if (!files.length) {
      selection.hidden = true;
      return;
    }
    files.forEach(function (file) {
      var item = document.createElement("li");
      var name = document.createElement("span");
      name.textContent = file.name;
      var size = document.createElement("span");
      size.className = "hint";
      size.textContent = formatSize(file.size);
      item.appendChild(name);
      item.appendChild(size);
      selection.appendChild(item);
    });
    selection.hidden = false;
  }

  if (input) {
    input.addEventListener("change", function () {
      renderSelection();
      showErrors([]);
    });
  }

  if (dropzone && input) {
    ["dragenter", "dragover"].forEach(function (name) {
      dropzone.addEventListener(name, function (event) {
        event.preventDefault();
        dropzone.classList.add("is-dragover");
      });
    });
    ["dragleave", "drop"].forEach(function (name) {
      dropzone.addEventListener(name, function (event) {
        event.preventDefault();
        dropzone.classList.remove("is-dragover");
      });
    });
    dropzone.addEventListener("drop", function (event) {
      if (event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files.length) {
        input.files = event.dataTransfer.files;
        renderSelection();
      }
    });
  }

  function setBusy(busy) {
    uploading = busy;
    if (submit) submit.disabled = busy;
    form.setAttribute("aria-busy", busy ? "true" : "false");
  }

  form.addEventListener("submit", function (event) {
    if (uploading) {
      event.preventDefault();
      return;
    }
    var files = selectedFiles();
    if (!files.length) {
      event.preventDefault();
      showErrors(["Selecciona al menos un archivo."]);
      return;
    }
    if (maxBytes) {
      var tooBig = files.filter(function (file) { return file.size > maxBytes; });
      if (tooBig.length) {
        event.preventDefault();
        showErrors(tooBig.map(function (file) {
          return file.name + ": supera el límite de " + formatSize(maxBytes) + ".";
        }));
        return;
      }
    }

    event.preventDefault();
    showErrors([]);
    setBusy(true);
    if (progress) progress.hidden = false;
    if (bar) bar.style.width = "0%";
    if (label) label.textContent = "Subiendo…";

    var xhr = new XMLHttpRequest();
    xhr.open("POST", form.action, true);
    xhr.setRequestHeader("X-Requested-With", "XMLHttpRequest");
    xhr.setRequestHeader("X-CSRFToken", window.SAD ? window.SAD.csrfToken() : "");

    xhr.upload.addEventListener("progress", function (progressEvent) {
      if (!progressEvent.lengthComputable) return;
      var percent = Math.round((progressEvent.loaded / progressEvent.total) * 100);
      if (bar) bar.style.width = percent + "%";
      if (label) label.textContent = "Subiendo… " + percent + "%";
    });

    xhr.addEventListener("load", function () {
      setBusy(false);
      var data = null;
      try { data = JSON.parse(xhr.responseText); } catch (error) { data = null; }

      if (xhr.status >= 200 && xhr.status < 300 && data && data.ok) {
        if (bar) bar.style.width = "100%";
        if (label) label.textContent = "¡Listo! Recargando…";
        if (data.errors && data.errors.length) {
          showErrors(data.errors);
          if (label) label.textContent = "Subida parcial";
        } else {
          window.setTimeout(function () { window.location.reload(); }, 550);
        }
        return;
      }

      if (label) label.textContent = "No se pudo subir";
      var messages = (data && data.errors) || [
        "No se pudo completar la subida (código " + xhr.status + "). " +
        "Revisa el tamaño y vuelve a intentarlo."
      ];
      showErrors(messages);
    });

    xhr.addEventListener("error", function () {
      setBusy(false);
      if (label) label.textContent = "Error de red";
      showErrors(["Error de red. Comprueba tu conexión e inténtalo de nuevo."]);
    });

    xhr.send(new FormData(form));
  });
})();
