// Codex Desktop RTL patch
// ------------------------
// Adds smart bidirectional (RTL) handling for Hebrew/Arabic text in the
// OpenAI Codex desktop app, while keeping code strictly left-to-right.
//
// Strategy (v0.2.0):
//   * Prose blocks that contain Hebrew/Arabic get a REAL `dir="rtl"` attribute.
//     A real dir gives correct ordering, correct `text-align:start` alignment,
//     AND native bidi isolation from siblings.
//   * We deliberately do NOT use `unicode-bidi: plaintext` on prose blocks.
//     plaintext re-derives the base direction from the first strong character
//     and ignores our `direction`, which made an inline `<code>` (a strong LTR
//     island) flip/merge the surrounding Hebrew. That was the inline-code bug.
//   * All code-like surfaces are forced LTR + isolated purely via CSS, so no
//     per-element JavaScript is needed to keep code correct.
//   * Direction policy: "any Hebrew (outside code) -> RTL". A Hebrew sentence
//     stays RTL even if it opens with `code` or an English word.
;(function () {
  "use strict";

  if (typeof document === "undefined") return;
  if (window.__codexRtlPatchVersion) return;
  window.__codexRtlPatchVersion = "0.2.0";

  // Attribute used to mark elements whose `dir` WE manage, so we never clobber
  // or remove a `dir` that the app itself set.
  var MARK = "data-codex-rtl";
  var STYLE_ID = "codex-rtl-patch-styles";

  // Editable surfaces (composer, inputs).
  var INPUT_SEL =
    '.ProseMirror, [contenteditable="true"], textarea, input[type="text"], input:not([type])';
  // Code-like surfaces that must always stay left-to-right.
  var CODE_SEL =
    'pre, code, kbd, samp, .cm-editor, .monaco-editor, .xterm, [class*="language-"], [class*="hljs"]';
  // Block-level prose elements.
  var TEXT_SEL =
    "p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, summary, dt, dd, figcaption";
  // Generic leaf containers (UI chrome) that might hold a bare RTL string.
  var LEAF_SEL = "div, span, button, a, label";
  // Nearest "paragraph" context used to scope incremental re-processing.
  var CTX_SEL = "p, li, h1, h2, h3, h4, h5, h6, blockquote, td, th, dt, dd";

  /* ----------------------------- detection ----------------------------- */

  function isRTLChar(code) {
    return (
      (code >= 0x0590 && code <= 0x05ff) || // Hebrew
      (code >= 0x0600 && code <= 0x06ff) || // Arabic
      (code >= 0x0750 && code <= 0x077f) || // Arabic Supplement
      (code >= 0x08a0 && code <= 0x08ff) || // Arabic Extended-A
      (code >= 0xfb1d && code <= 0xfdff) || // Hebrew + Arabic Presentation A
      (code >= 0xfe70 && code <= 0xfeff)    // Arabic Presentation Forms B
    );
  }

  function hasRTL(text) {
    if (!text) return false;
    for (var i = 0; i < text.length; i += 1) {
      if (isRTLChar(text.charCodeAt(i))) return true;
    }
    return false;
  }

  // Element text with anything inside code-like surfaces removed, so a Hebrew
  // comment *inside* code never flips the surrounding paragraph.
  function textWithoutCode(el) {
    var out = "";
    var nodes = el.childNodes || [];
    for (var i = 0; i < nodes.length; i += 1) {
      var node = nodes[i];
      if (node.nodeType === 3) {
        out += node.textContent || "";
      } else if (node.nodeType === 1 && node.matches && !node.matches(CODE_SEL)) {
        out += textWithoutCode(node);
      }
    }
    return out;
  }

  /* ------------------------------ helpers ------------------------------ */

  function qsa(root, selector) {
    var base = root && root.querySelectorAll ? root : document;
    var result = Array.prototype.slice.call(base.querySelectorAll(selector));
    if (root && root.nodeType === 1 && root.matches && root.matches(selector)) {
      result.unshift(root);
    }
    return result;
  }

  function isEditable(el) {
    return !!(el && el.closest && el.closest(INPUT_SEL));
  }

  function inCode(el) {
    return !!(el && el.closest && el.closest(CODE_SEL));
  }

  function hasBlockChild(el) {
    return !!el.querySelector(
      "p, div, ul, ol, li, h1, h2, h3, h4, h5, h6, pre, table, blockquote"
    );
  }

  // Set or clear the dir attribute. We only ever clear a dir we set ourselves.
  function applyDir(el, dir) {
    var owned = el.hasAttribute(MARK);
    if (!dir) {
      if (owned) {
        el.removeAttribute("dir");
        el.removeAttribute(MARK);
      }
      return;
    }
    if (el.getAttribute("dir") !== dir) el.setAttribute("dir", dir);
    if (!owned) el.setAttribute(MARK, "1");
  }

  // Policy: a block is RTL iff its non-code text contains any Hebrew/Arabic.
  function rtlIfHebrew(el) {
    return hasRTL(textWithoutCode(el)) ? "rtl" : null;
  }

  /* --------------------------- processing ------------------------------ */

  function processText(root) {
    qsa(root, TEXT_SEL).forEach(function (el) {
      if (isEditable(el) || inCode(el)) return;
      applyDir(el, rtlIfHebrew(el));
    });
  }

  function processLists(root) {
    qsa(root, "ul, ol").forEach(function (el) {
      if (isEditable(el) || inCode(el)) return;
      applyDir(el, rtlIfHebrew(el));
    });
  }

  function processLeafContainers(root) {
    qsa(root, LEAF_SEL).forEach(function (el) {
      if (isEditable(el) || inCode(el)) return;
      if (/^(P|LI|H[1-6]|BLOCKQUOTE|TD|TH|UL|OL|PRE|CODE|DT|DD)$/.test(el.tagName)) return;
      if (hasBlockChild(el)) return;
      if ((el.textContent || "").trim().length < 2) {
        applyDir(el, null);
        return;
      }
      applyDir(el, rtlIfHebrew(el));
    });
  }

  function processInputs(root) {
    qsa(root, INPUT_SEL).forEach(function (el) {
      if (inCode(el)) return;
      var text = el.value || el.textContent || el.innerText || "";
      var dir = hasRTL(text) ? "rtl" : "ltr";
      if (el.getAttribute("dir") !== dir) el.setAttribute("dir", dir);
      // For editable fields, plaintext gives natural per-line direction as you type.
      if (el.style.unicodeBidi !== "plaintext") el.style.unicodeBidi = "plaintext";
      if (el.style.textAlign !== "start") el.style.textAlign = "start";
    });
  }

  function processAll(root) {
    var target = root && root.nodeType === 1 ? root : document.body;
    if (!target) return;
    processText(target);
    processLists(target);
    processLeafContainers(target);
    processInputs(target);
  }

  /* ---------------------------- stylesheet ----------------------------- */

  function injectStyles() {
    if (document.getElementById(STYLE_ID)) return;
    var css = [
      // RTL prose we flipped is aligned to the start (= right for rtl).
      "[" + MARK + "]{text-align:start!important}",
      // RTL lists keep their bullet/number markers on the start (right) edge.
      'ul[dir="rtl"],ol[dir="rtl"]{list-style-position:outside}',
      // Every code-like surface stays LTR and isolated, regardless of context.
      ':where(pre,code,kbd,samp,[class*="language-"],[class*="hljs"],.cm-editor,.monaco-editor,.xterm){direction:ltr!important;text-align:left!important}',
      "code{unicode-bidi:isolate!important}",
      "pre{unicode-bidi:isolate!important}",
      // Editable surfaces follow their detected direction.
      '.ProseMirror[dir],[contenteditable="true"][dir]{text-align:start!important}'
    ].join("");
    var style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  }

  /* --------------------------- bootstrap ------------------------------- */

  var raf = window.requestAnimationFrame
    ? window.requestAnimationFrame.bind(window)
    : function (cb) { return window.setTimeout(cb, 16); };

  function init() {
    injectStyles();
    processAll(document.body || document);

    // Fast path for the composer / inputs.
    document.addEventListener(
      "input",
      function (event) {
        var t = event.target;
        if (t && t.closest && t.closest(INPUT_SEL)) processInputs(t.closest(INPUT_SEL));
      },
      true
    );

    // Incremental re-processing: only touch the subtree / paragraph that changed.
    var queue = new Set();
    var scheduled = false;

    function contextOf(node) {
      var el = node && node.nodeType === 1 ? node : node && node.parentNode;
      if (!el || el.nodeType !== 1) return null;
      return (el.closest && el.closest(CTX_SEL)) || el;
    }

    function flush() {
      scheduled = false;
      var roots = Array.from(queue);
      queue.clear();
      for (var i = 0; i < roots.length; i += 1) {
        if (roots[i] && roots[i].isConnected) processAll(roots[i]);
      }
    }

    function schedule(node) {
      var ctx = contextOf(node);
      if (!ctx) return;
      queue.add(ctx);
      if (!scheduled) {
        scheduled = true;
        raf(flush);
      }
    }

    var observer = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i += 1) {
        var m = mutations[i];
        if (m.type === "characterData" || m.type === "attributes") {
          schedule(m.target);
        } else {
          for (var j = 0; j < m.addedNodes.length; j += 1) {
            schedule(m.addedNodes[j]);
          }
        }
      }
    });

    if (document.body) {
      // We also watch the `dir` attribute so that if a React re-render strips a
      // dir we set, we re-apply it. applyDir() is idempotent (it writes only when
      // the value actually changes), so reacting to our own writes cannot loop.
      observer.observe(document.body, {
        childList: true,
        subtree: true,
        characterData: true,
        attributes: true,
        attributeFilter: ["dir"]
      });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
