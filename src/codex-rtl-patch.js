// Codex Desktop RTL patch
// ------------------------
// Adds smart bidirectional (RTL) handling for Hebrew/Arabic text in the
// OpenAI Codex desktop app, while keeping code and math strictly left-to-right.
//
// Strategy (v1.3.0):
//   * Prose blocks that contain Hebrew/Arabic get a REAL `dir="rtl"` attribute.
//     A real dir gives correct ordering, correct `text-align:start` alignment,
//     AND native bidi isolation from siblings.
//   * We deliberately do NOT use `unicode-bidi: plaintext` on prose blocks.
//     plaintext re-derives the base direction from the first strong character
//     and ignores our `direction`, which made an inline `<code>` (a strong LTR
//     island) flip/merge the surrounding Hebrew. That was the inline-code bug.
//   * All code-like surfaces are forced LTR + isolated purely via CSS.
//   * Math islands (LaTeX "$...$", "\(...\)", "\[...\]", and bare arithmetic like
//     "2 + 3 = 5") are wrapped in isolated LTR spans, so they never render
//     mirrored ("5 = 3 + 2") inside a Hebrew paragraph.
//   * Hebrew tables flip whole-column order (dir="rtl" on the <table>), decided by
//     the majority direction of the header / first column.
//
// Configurable: a sibling `codex-rtl-config.js` asset may set
//   window.__codexRtlConfig = { enabled, direction:{policy}, surfaces:{...}, font:{...} }
// BEFORE this script runs. When absent, every setting falls back to the historical
// defaults, so an unconfigured install behaves like the previous release (plus the
// new, default-on math/table handling).
//   * direction.policy: "anyHebrew" (default) or "firstStrong".
//   * surfaces: prose / inputs / tables / math / codeIsolation booleans (default true).
//   * font: { override, family, sizePercent } to restyle flipped prose only.
;(function () {
  "use strict";

  if (typeof document === "undefined") return;
  if (window.__codexRtlPatchVersion) return;
  window.__codexRtlPatchVersion = "1.3.0";

  /* ---------------------------- configuration -------------------------- */

  var CFG = (window && window.__codexRtlConfig) || {};
  if (CFG.enabled === false) return;
  var POLICY = (CFG.direction && CFG.direction.policy) === "firstStrong" ? "firstStrong" : "anyHebrew";
  var SURF = CFG.surfaces || {};
  var S_PROSE = SURF.prose !== false;
  var S_INPUTS = SURF.inputs !== false;
  var S_TABLES = SURF.tables !== false;
  var S_MATH = SURF.math !== false;
  var S_CODEISO = SURF.codeIsolation !== false;
  var FONT = CFG.font || null;

  var MARK = "data-codex-rtl";
  var ISLAND_FLAG = "data-codex-rtl-island";
  var TABLE_FLAG = "data-codex-rtl-table";
  var STYLE_ID = "codex-rtl-patch-styles";

  var INPUT_SEL =
    '.ProseMirror, [contenteditable="true"], textarea, input[type="text"], input:not([type])';
  var CODE_SEL =
    'pre, code, kbd, samp, .cm-editor, .monaco-editor, .xterm, [class*="language-"], [class*="hljs"]';
  var TEXT_SEL =
    "p, li, h1, h2, h3, h4, h5, h6, blockquote, summary, dt, dd, figcaption";
  var TABLE_CELL_SEL = "td, th";
  var LEAF_SEL = "div, span, button, a, label";
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

  function isStrongLTRChar(code) {
    return (
      (code >= 0x0041 && code <= 0x005a) ||
      (code >= 0x0061 && code <= 0x007a) ||
      (code >= 0x00c0 && code <= 0x024f) ||
      (code >= 0x0370 && code <= 0x03ff) ||
      (code >= 0x0400 && code <= 0x04ff)
    );
  }

  function hasRTL(text) {
    if (!text) return false;
    for (var i = 0; i < text.length; i += 1) {
      if (isRTLChar(text.charCodeAt(i))) return true;
    }
    return false;
  }

  function firstStrongDir(text) {
    if (!text) return null;
    for (var i = 0; i < text.length; i += 1) {
      var c = text.charCodeAt(i);
      if (isRTLChar(c)) return "rtl";
      if (isStrongLTRChar(c)) return "ltr";
    }
    return null;
  }

  // Remove leading LTR-only noise (filenames, URLs, paths, backtick-code) so a
  // Hebrew sentence that opens with "foo.js" still detects as RTL under firstStrong.
  function stripLeadingLTR(text) {
    return text
      .replace(/^[\s]*(?:[\w.\-]+\.[\w]{1,5})\s*/g, "")
      .replace(/https?:\/\/\S+/g, "")
      .replace(/[\w.\-]+[\/\\][\w.\-\/\\]+/g, "")
      .replace(/`[^`]+`/g, "");
  }

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

  /* --------------------------- math detection -------------------------- */
  // Raw LaTeX + bare-arithmetic isolation, so math never renders mirrored in RTL.

  var LATEX_SIGNAL = /[\\^_{}]|\b(?:frac|sqrt|sum|prod|int|lim|infty|cdot|times|div|leq|geq|neq|approx|partial|nabla|alpha|beta|gamma|delta|theta|lambda|mu|pi|sigma|omega|matrix|begin|end|left|right|text|mathbb|mathcal|vec|hat|bar|overline|underline)\b/;

  function hasLatexSignal(body) { return LATEX_SIGNAL.test(body); }

  function findLatexRanges(text) {
    var ranges = [];
    if (!text) return ranges;
    function overlaps(s, e) {
      for (var i = 0; i < ranges.length; i += 1) {
        if (s < ranges[i][1] && e > ranges[i][0]) return true;
      }
      return false;
    }
    function claim(re, requireSignal, bodyStart, bodyEnd) {
      var m;
      re.lastIndex = 0;
      while ((m = re.exec(text)) !== null) {
        var start = m.index;
        var end = m.index + m[0].length;
        if (overlaps(start, end)) continue;
        if (requireSignal) {
          var body = m[0].slice(bodyStart, m[0].length - bodyEnd);
          if (!hasLatexSignal(body)) continue;
        }
        ranges.push([start, end]);
      }
    }
    claim(/\$\$[\s\S]+?\$\$/g, false, 0, 0);
    claim(/\\\[[\s\S]+?\\\]/g, false, 0, 0);
    claim(/\\\([\s\S]+?\\\)/g, false, 0, 0);
    claim(/\$[^$\n]+?\$/g, true, 1, 1); // single $...$ needs a LaTeX signal (currency guard)
    ranges.sort(function (a, b) { return a[0] - b[0]; });
    return ranges;
  }

  // Math operator chars, built from code points so this source stays ASCII.
  var MATH_OP_CHARS = "+\\-*/=<>%" + String.fromCharCode(
    0xd7, 0xf7, 0xb1, 0x2212, 0x2264, 0x2265, 0x2260,
    0x2248, 0x2192, 0xb7, 0x2022, 0x2219, 0x2217, 0x22c5, 0x221a);
  var MATH_OP_RE = new RegExp("[" + MATH_OP_CHARS + "]");
  var MATH_DIGIT_RE = /[0-9]/;
  var MATH_TOKEN_RE = new RegExp("^(?:[0-9.,:;()\\[\\]{}|" + MATH_OP_CHARS + "]+|[A-Za-z])$");

  function isMathyToken(tok) { return !!tok && MATH_TOKEN_RE.test(tok); }
  function isOperandToken(tok) { return MATH_DIGIT_RE.test(tok) || /^[A-Za-z]$/.test(tok); }

  function findMathRanges(text) {
    var ranges = [];
    if (!text || !MATH_OP_RE.test(text) || !MATH_DIGIT_RE.test(text)) return ranges;
    var base = 0;
    var lines = text.split("\n");
    for (var li = 0; li < lines.length; li += 1) {
      scanLine(lines[li], base);
      base += lines[li].length + 1;
    }
    return ranges;

    function scanLine(line, off) {
      var toks = [];
      var re = /\S+/g;
      var m;
      while ((m = re.exec(line)) !== null) {
        toks.push({ v: m[0], start: m.index, end: m.index + m[0].length });
      }
      var i = 0;
      while (i < toks.length) {
        if (!isMathyToken(toks[i].v)) { i += 1; continue; }
        var j = i;
        while (j + 1 < toks.length && isMathyToken(toks[j + 1].v)) j += 1;
        var a = i, b = j;
        while (a <= b && !isOperandToken(toks[a].v)) a += 1;
        while (b >= a && !isOperandToken(toks[b].v)) b -= 1;
        if (a <= b) {
          var s = off + toks[a].start;
          var e = off + toks[b].end;
          while (e > s && ".,:;".indexOf(text.charAt(e - 1)) !== -1) e -= 1;
          while (e > s && ",:;".indexOf(text.charAt(s)) !== -1) s += 1;
          var sub = text.slice(s, e);
          if (e - s >= 2 && MATH_DIGIT_RE.test(sub) && MATH_OP_RE.test(sub)) {
            ranges.push([s, e]);
          }
        }
        i = j + 1;
      }
    }
  }

  // Split text into alternating {type:'text'|'math'} segments (LaTeX wins on clash).
  function segmentText(text) {
    var segs = [];
    if (!text) return segs;
    var ranges = findLatexRanges(text);
    var numeric = findMathRanges(text);
    for (var n = 0; n < numeric.length; n += 1) {
      var ns = numeric[n][0], ne = numeric[n][1], clash = false;
      for (var c = 0; c < ranges.length; c += 1) {
        if (ns < ranges[c][1] && ne > ranges[c][0]) { clash = true; break; }
      }
      if (!clash) ranges.push(numeric[n]);
    }
    if (!ranges.length) { segs.push({ type: "text", value: text }); return segs; }
    ranges.sort(function (a, b) { return a[0] - b[0]; });
    var pos = 0;
    for (var i = 0; i < ranges.length; i += 1) {
      if (ranges[i][0] > pos) segs.push({ type: "text", value: text.slice(pos, ranges[i][0]) });
      segs.push({ type: "math", value: text.slice(ranges[i][0], ranges[i][1]) });
      pos = ranges[i][1];
    }
    if (pos < text.length) segs.push({ type: "text", value: text.slice(pos) });
    return segs;
  }

  /* --------------------------- table detection ------------------------- */

  function cellDir(text) {
    if (hasRTL(text)) return "rtl";
    if (firstStrongDir(text) === "ltr") return "ltr";
    return null;
  }
  function majorityDir(dirs) {
    var r = 0, l = 0;
    for (var i = 0; i < dirs.length; i += 1) {
      if (dirs[i] === "rtl") r += 1; else if (dirs[i] === "ltr") l += 1;
    }
    if (r > l) return "rtl";
    if (l > r) return "ltr";
    return null;
  }
  function tableDirFromCells(headerDirs, firstColDirs) {
    if (headerDirs && headerDirs[0] === "rtl" && firstColDirs && firstColDirs[0] === "rtl") return "rtl";
    var h = majorityDir(headerDirs || []);
    if (h === "rtl") return "rtl";
    if (h === "ltr") return null;
    return majorityDir(firstColDirs || []) === "rtl" ? "rtl" : null;
  }

  /* ------------------------------ helpers ------------------------------ */

  function qsa(root, selector) {
    var base = root && root.querySelectorAll ? root : document;
    var result = Array.prototype.slice.call(base.querySelectorAll(selector));
    if (root && root.nodeType === 1 && root.matches && root.matches(selector)) result.unshift(root);
    return result;
  }
  function isEditable(el) { return !!(el && el.closest && el.closest(INPUT_SEL)); }
  function inCode(el) { return !!(el && el.closest && el.closest(CODE_SEL)); }
  function hasBlockChild(el) {
    return !!el.querySelector("p, div, ul, ol, li, h1, h2, h3, h4, h5, h6, pre, table, blockquote");
  }

  function applyDir(el, dir) {
    var owned = el.hasAttribute(MARK);
    if (!dir) {
      if (owned) { el.removeAttribute("dir"); el.removeAttribute(MARK); }
      return;
    }
    if (el.getAttribute("dir") !== dir) el.setAttribute("dir", dir);
    if (!owned) el.setAttribute(MARK, "1");
  }

  // Policy-driven base direction: only ever returns "rtl" or null.
  function rtlDirFor(el) {
    var text = textWithoutCode(el);
    if (POLICY === "firstStrong") {
      if (firstStrongDir(text) === "rtl") return "rtl";
      // A Hebrew line that merely opens with a filename / URL / path still counts.
      return firstStrongDir(stripLeadingLTR(text)) === "rtl" ? "rtl" : null;
    }
    return hasRTL(text) ? "rtl" : null; // anyHebrew (default)
  }

  /* --------------------------- processing ------------------------------ */

  // Wrap LaTeX / bare-arithmetic runs in isolated LTR spans. Uses replaceChild on a
  // single text node (never innerHTML) to stay gentle on React reconciliation, and
  // flags islands so streaming never re-wraps them.
  function isolateMath(root) {
    if (typeof document.createTreeWalker !== "function") return;
    var host = root && root.nodeType === 1 ? root : document.body;
    if (!host) return;
    var walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        var v = node.nodeValue;
        if (!v) return NodeFilter.FILTER_REJECT;
        var hasTex = v.indexOf("$") !== -1 || v.indexOf("\\") !== -1;
        var hasNum = MATH_DIGIT_RE.test(v) && MATH_OP_RE.test(v);
        if (!hasTex && !hasNum) return NodeFilter.FILTER_REJECT;
        var p = node.parentElement;
        if (!p) return NodeFilter.FILTER_REJECT;
        if (p.tagName === "SCRIPT" || p.tagName === "STYLE") return NodeFilter.FILTER_REJECT;
        if (p.closest(CODE_SEL) || p.closest(INPUT_SEL) || p.closest("[" + ISLAND_FLAG + "]")) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var targets = [];
    var n;
    while ((n = walker.nextNode())) targets.push(n);
    targets.forEach(function (textNode) {
      var segs = segmentText(textNode.nodeValue);
      if (!segs.some(function (s) { return s.type === "math"; })) return;
      var frag = document.createDocumentFragment();
      segs.forEach(function (s) {
        if (s.type === "math") {
          var span = document.createElement("span");
          span.setAttribute(ISLAND_FLAG, "1");
          span.style.unicodeBidi = "isolate";
          span.style.direction = "ltr";
          span.textContent = s.value;
          frag.appendChild(span);
        } else {
          frag.appendChild(document.createTextNode(s.value));
        }
      });
      if (textNode.parentNode) textNode.parentNode.replaceChild(frag, textNode);
    });
  }

  function processText(root) {
    qsa(root, TEXT_SEL).forEach(function (el) {
      if (isEditable(el) || inCode(el)) return;
      applyDir(el, rtlDirFor(el));
    });
  }

  function processTableCells(root) {
    qsa(root, TABLE_CELL_SEL).forEach(function (el) {
      if (isEditable(el) || inCode(el)) return;
      applyDir(el, rtlDirFor(el));
    });
  }

  // Flip a Hebrew table's whole column order (first column on the right), decided by
  // the majority direction of the header / first column. Cells keep their own dir.
  function processTableColumns(root) {
    qsa(root, "table").forEach(function (t) {
      if (t.getAttribute(TABLE_FLAG) === "rtl") return;
      if (isEditable(t) || inCode(t)) return;
      var headerCells = Array.prototype.slice.call(t.querySelectorAll("thead th"));
      if (!headerCells.length) {
        var firstRow = t.querySelector("tr");
        if (firstRow) headerCells = Array.prototype.slice.call(firstRow.querySelectorAll("th, td"));
      }
      var headerDirs = headerCells.map(function (c) { return cellDir(c.textContent || ""); });
      var rows = Array.prototype.slice.call(t.querySelectorAll("tbody tr"));
      if (!rows.length) rows = Array.prototype.slice.call(t.querySelectorAll("tr")).slice(1);
      var firstColDirs = rows.map(function (r) {
        var cell = r.querySelector("th, td");
        return cell ? cellDir(cell.textContent || "") : null;
      });
      if (tableDirFromCells(headerDirs, firstColDirs) === "rtl") {
        t.setAttribute(TABLE_FLAG, "rtl");
        if (t.getAttribute("dir") !== "rtl") t.setAttribute("dir", "rtl");
      }
    });
  }

  function processLists(root) {
    qsa(root, "ul, ol").forEach(function (el) {
      if (isEditable(el) || inCode(el)) return;
      applyDir(el, rtlDirFor(el));
    });
  }

  function processLeafContainers(root) {
    qsa(root, LEAF_SEL).forEach(function (el) {
      if (isEditable(el) || inCode(el)) return;
      if (el.hasAttribute(ISLAND_FLAG)) return;
      if (/^(P|LI|H[1-6]|BLOCKQUOTE|TD|TH|UL|OL|PRE|CODE|DT|DD)$/.test(el.tagName)) return;
      if (hasBlockChild(el)) return;
      if ((el.textContent || "").trim().length < 2) { applyDir(el, null); return; }
      applyDir(el, rtlDirFor(el));
    });
  }

  function processInputs(root) {
    qsa(root, INPUT_SEL).forEach(function (el) {
      if (inCode(el)) return;
      var text = el.value || el.textContent || el.innerText || "";
      var dir = hasRTL(text) ? "rtl" : "ltr";
      if (el.getAttribute("dir") !== dir) el.setAttribute("dir", dir);
      if (el.style.unicodeBidi !== "plaintext") el.style.unicodeBidi = "plaintext";
      if (el.style.textAlign !== "start") el.style.textAlign = "start";
    });
  }

  function processAll(root) {
    var target = root && root.nodeType === 1 ? root : document.body;
    if (!target) return;
    if (S_MATH) isolateMath(target);
    if (S_PROSE) { processText(target); processLists(target); }
    if (S_TABLES) { processTableCells(target); processTableColumns(target); }
    processLeafContainers(target);
    if (S_INPUTS) processInputs(target);
  }

  /* ---------------------------- stylesheet ----------------------------- */

  function sanitizeFontFamily(fam) {
    if (!fam || typeof fam !== "string") return "";
    return fam.replace(/[<>{}();]/g, "").replace(/[\r\n]+/g, " ").trim().slice(0, 200);
  }
  function clampSizePercent(n) {
    n = parseInt(n, 10);
    if (isNaN(n)) return 100;
    if (n < 80) return 80;
    if (n > 150) return 150;
    return n;
  }

  function injectStyles() {
    if (document.getElementById(STYLE_ID)) return;
    var css = [
      "[" + MARK + "]{text-align:start!important}",
      'ul[dir="rtl"],ol[dir="rtl"]{list-style-position:outside}',
      'table[dir="rtl"]{direction:rtl!important}',
      '.ProseMirror[dir],[contenteditable="true"][dir]{text-align:start!important}'
    ];
    if (S_MATH) {
      // Isolated LTR math islands (raw LaTeX / arithmetic) and any rendered math.
      css.push("[" + ISLAND_FLAG + "]{unicode-bidi:isolate!important;direction:ltr!important}");
      css.push(".katex,.katex-display,mjx-container{unicode-bidi:isolate!important;direction:ltr!important}");
    }
    if (S_CODEISO) {
      css.push(':where(pre,code,kbd,samp,[class*="language-"],[class*="hljs"],.cm-editor,.monaco-editor,.xterm){direction:ltr!important;text-align:left!important}');
      css.push("code{unicode-bidi:isolate!important}");
      css.push("pre{unicode-bidi:isolate!important}");
    }
    if (FONT && FONT.override) {
      var fam = sanitizeFontFamily(FONT.family);
      if (fam) css.push("[" + MARK + "]{font-family:" + fam + "!important}");
      var pct = clampSizePercent(FONT.sizePercent);
      if (pct !== 100) css.push("[" + MARK + "]:not(pre):not(code){font-size:" + pct + "%!important}");
    }
    var style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = css.join("");
    (document.head || document.documentElement).appendChild(style);
  }

  /* --------------------------- bootstrap ------------------------------- */

  var raf = window.requestAnimationFrame
    ? window.requestAnimationFrame.bind(window)
    : function (cb) { return window.setTimeout(cb, 16); };

  function init() {
    injectStyles();
    processAll(document.body || document);

    if (S_INPUTS) {
      document.addEventListener("input", function (event) {
        var t = event.target;
        if (t && t.closest && t.closest(INPUT_SEL)) processInputs(t.closest(INPUT_SEL));
      }, true);
    }

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
      if (!scheduled) { scheduled = true; raf(flush); }
    }

    var observer = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i += 1) {
        var m = mutations[i];
        if (m.type === "characterData" || m.type === "attributes") {
          schedule(m.target);
        } else {
          for (var j = 0; j < m.addedNodes.length; j += 1) schedule(m.addedNodes[j]);
        }
      }
    });

    if (document.body) {
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
