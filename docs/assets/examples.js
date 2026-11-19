// Examples page (docs/examples.md): lists the approved examples from the examples service (worker/) and uploads
// new ones to it. Listeners are delegated from the document, and the gallery is filled on every page load through
// Material's document$, so both survive instant navigation.
(function () {
  "use strict";
  var MAX_BYTES = 95 * 1024 * 1024; // keep in sync with worker/src/index.ts

  function megabytes(size) {
    return size < 1024 * 1024 ? Math.ceil(size / 1024) + " KB" : (size / (1024 * 1024)).toFixed(1) + " MB";
  }

  function element(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  function service() {
    var gallery = document.querySelector(".mb-examples");
    return gallery ? gallery.getAttribute("data-service") : null;
  }

  function card(example) {
    var item = element("article", "mb-example");
    item.appendChild(element("h3", null, example.title));
    var byline = [example.authors, example.institution, example.date].filter(Boolean).join(" · ");
    item.appendChild(element("p", "mb-example-byline", byline));
    if (example.description) item.appendChild(element("p", "mb-example-description", example.description));
    if (example.keywords && example.keywords.length) {
      var tags = element("p", "mb-example-keywords");
      example.keywords.forEach(function (k) { tags.appendChild(element("span", null, k)); });
      item.appendChild(tags);
    }
    var link = element("a", "md-button", "Download (" + megabytes(example.size) + ")");
    link.href = example.download_url;
    link.setAttribute("download", "");
    item.appendChild(link);
    return item;
  }

  function loadGallery() {
    var gallery = document.querySelector(".mb-examples");
    if (!gallery || gallery.getAttribute("data-loaded")) return;
    gallery.setAttribute("data-loaded", "1");
    fetch(service() + "/examples")
      .then(function (r) { return r.ok ? r.json() : { examples: [] }; })
      .then(function (data) {
        if (!data.examples || !data.examples.length) return;
        gallery.textContent = "";
        gallery.classList.add("mb-examples-grid");
        data.examples.forEach(function (e) { gallery.appendChild(card(e)); });
      })
      .catch(function () { /* keep the "No examples yet" note */ });
  }

  if (window.document$ && window.document$.subscribe) window.document$.subscribe(loadGallery);
  else document.addEventListener("DOMContentLoaded", loadGallery);

  function status(form, text, kind) {
    var line = form.querySelector(".mb-submit-status");
    line.textContent = text;
    line.classList.toggle("mb-error", kind === "error");
    line.classList.toggle("mb-success", kind === "success");
  }

  function fileProblem(file) {
    if (!/\.manimble$/i.test(file.name)) return "Choose a .manimble package (File ▸ Package for Sharing… in Manimble).";
    if (file.size > MAX_BYTES) {
      return file.name + " is " + megabytes(file.size) + "; examples can be at most 95 MB. See below for larger ones.";
    }
    return null;
  }

  document.addEventListener("click", function (event) {
    var toggle = event.target.closest && event.target.closest(".mb-submit-toggle");
    var form = toggle && document.querySelector(".mb-submit-form");
    if (!form) return;
    event.preventDefault();
    form.scrollIntoView({ behavior: "smooth", block: "center" });
    form.querySelector("input[type=file]").focus({ preventScroll: true });
  });

  document.addEventListener("change", function (event) {
    var input = event.target;
    if (!input.matches || !input.matches(".mb-submit-form input[type=file]")) return;
    var form = input.form, file = input.files[0];
    if (!file) return status(form, "");
    var problem = fileProblem(file);
    if (problem) return status(form, problem, "error");
    if (!form.elements.title.value) form.elements.title.value = file.name.replace(/\.manimble$/i, "").replace(/[_-]+/g, " ");
    status(form, file.name + " (" + megabytes(file.size) + ") is ready.");
  });

  document.addEventListener("submit", function (event) {
    var form = event.target;
    if (!form.matches || !form.matches(".mb-submit-form")) return;
    event.preventDefault();
    var file = form.elements.file.files[0];
    var problem = fileProblem(file);
    if (problem) return status(form, problem, "error");
    var meta = { agree: form.elements.agree.checked };
    ["title", "authors", "institution", "date", "keywords", "description"].forEach(function (name) {
      meta[name] = form.elements[name].value.trim();
    });
    var button = form.querySelector("button[type=submit]");
    var bar = form.querySelector("progress");
    var xhr = new XMLHttpRequest();
    xhr.open("POST", service() + "/submit");
    xhr.setRequestHeader("content-type", "application/zip");
    xhr.setRequestHeader("x-manimble-meta", encodeURIComponent(JSON.stringify(meta)));
    xhr.upload.onprogress = function (e) {
      if (e.lengthComputable) bar.value = e.loaded / e.total;
    };
    xhr.onloadend = function () {
      button.disabled = false;
      bar.hidden = true;
      var reply = {};
      try { reply = JSON.parse(xhr.responseText); } catch (e) { /* not JSON */ }
      if (xhr.status === 201) {
        form.reset();
        status(form, "Thank you! “" + meta.title + "” was submitted, and will appear here once it has been reviewed.", "success");
      } else {
        status(form, reply.error || "The upload failed. Check your connection and try again.", "error");
      }
    };
    button.disabled = true;
    bar.value = 0;
    bar.hidden = false;
    status(form, "Uploading " + file.name + "…");
    xhr.send(file);
  });
})();
