// Examples page (docs/examples.md): lists the presentations in examples/gallery/examples.json, read from GitHub on
// every page load (so new examples appear without rebuilding the site). Filled through Material's document$, so it
// survives instant navigation.
(function () {
  "use strict";

  function element(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  function card(example, files) {
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
    var link = element("a", "md-button", "Download");
    link.href = files + encodeURIComponent(example.file);
    link.setAttribute("download", example.file);
    item.appendChild(link);
    return item;
  }

  function loadGallery() {
    var gallery = document.querySelector(".mb-examples");
    if (!gallery || gallery.getAttribute("data-loaded")) return;
    gallery.setAttribute("data-loaded", "1");
    var files = gallery.getAttribute("data-files");
    fetch(gallery.getAttribute("data-manifest"), { cache: "no-cache" })
      .then(function (r) { return r.ok ? r.json() : []; })
      .then(function (examples) {
        examples = (examples || []).filter(function (e) { return e && e.file && e.title; });
        if (!examples.length) return;
        gallery.textContent = "";
        gallery.classList.add("mb-examples-grid");
        examples.forEach(function (e) { gallery.appendChild(card(e, files)); });
      })
      .catch(function () { /* keep the placeholder note */ });
  }

  if (window.document$ && window.document$.subscribe) window.document$.subscribe(loadGallery);
  else document.addEventListener("DOMContentLoaded", loadGallery);
})();
