/* Overlord Activity dashboard. No external requests: loads data/activity.json, falls back to data/sample.json. */
(function () {
  "use strict";

  var DAY = 86400, WEEK = 7 * DAY;
  var SERIES = ["#e0a83a", "#5ab0f0", "#e2584c", "#6cc070", "#b48ce6", "#e07fb5", "#4fd1c5", "#c9b458"];
  var DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
  var SVGNS = "http://www.w3.org/2000/svg";
  var state = { topWin: "30", heatWin: "all", heatMetric: "rate", trendMetric: "total", showAllSessions: false };
  var D = null; // loaded data
  var nf0 = new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 });
  var nf1 = new Intl.NumberFormat(undefined, { maximumFractionDigits: 1, minimumFractionDigits: 1 });

  // ---------- helpers ----------
  function $(s) { return document.querySelector(s); }
  function el(tag, attrs) {
    var e = document.createElement(tag);
    if (attrs) for (var k in attrs) {
      if (k === "text") e.textContent = attrs[k];
      else if (k === "cls") e.className = attrs[k];
      else e.setAttribute(k, attrs[k]);
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c == null) continue;
      e.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
    }
    return e;
  }
  function sv(tag, attrs, text) {
    var e = document.createElementNS(SVGNS, tag);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;
    return e;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); return node; }
  function dash(v, f) { return v == null ? "–" : (f || nf0.format)(v); }
  function fmtHours(sec) { return nf1.format(sec / 3600) + " h"; }
  function fmtDur(sec) { var m = Math.round(sec / 60); return m >= 60 ? Math.floor(m / 60) + " h " + (m % 60) + " min" : m + " min"; }
  function dt(t, opt) { return new Date(t * 1000).toLocaleString(undefined, opt || { weekday: "short", year: "numeric", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }); }
  function dateOnly(t) { return new Date(t * 1000).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric", year: "numeric" }); }
  function timeOnly(t) { return new Date(t * 1000).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }); }
  function tzLabel() {
    var tz = "local time";
    try { tz = Intl.DateTimeFormat().resolvedOptions().timeZone || tz; } catch (e) { /* ignore */ }
    var off = -new Date().getTimezoneOffset(), sign = off >= 0 ? "+" : "-";
    off = Math.abs(off);
    return tz + " (UTC" + sign + String(Math.floor(off / 60)).padStart(2, "0") + ":" + String(off % 60).padStart(2, "0") + ")";
  }
  function weekdayIdx(d) { return (d.getDay() + 6) % 7; } // Monday = 0
  function localDayStart(t) { var d = new Date(t * 1000); d.setHours(0, 0, 0, 0); return Math.floor(d.getTime() / 1000); }
  function dayKey(t) { var d = new Date(t * 1000); return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0"); }
  function fightName(k) { var f = D.names.fights[k]; return f ? f.name : k; }
  function fightKind(k) { var f = D.names.fights[k]; return f && f.kind === "w" ? "Outside the fronts" : "Front"; }
  function est(sum) { return sum / 10; }
  function bucketEst(b) { var s = 0; for (var k in b.f) s += b.f[k][0]; return est(s); }
  function windowStart(win) { return win === "all" ? -Infinity : D.generated - Number(win) * DAY; }
  function inWin(b, win) { return b.t >= windowStart(win) && b.t <= D.generated; }

  function table(head, rows, numCols) {
    var t = el("table"), tr = el("tr");
    head.forEach(function (h, i) { tr.appendChild(el("th", { scope: "col", cls: numCols && numCols.indexOf(i) >= 0 ? "num" : "" }, h)); });
    t.appendChild(el("thead", null, tr));
    var tb = el("tbody");
    rows.forEach(function (r) {
      var row = el("tr");
      r.forEach(function (c, i) {
        var td = el("td", { cls: numCols && numCols.indexOf(i) >= 0 ? "num" : "" });
        if (c instanceof Node) td.appendChild(c); else td.textContent = c == null ? "" : String(c);
        row.appendChild(td);
      });
      tb.appendChild(row);
    });
    t.appendChild(tb);
    return t;
  }
  function empty(text) { return el("div", { cls: "empty" }, text); }
  function bar(frac, color) {
    var b = el("div", { cls: "bar" }), s = el("span");
    s.style.width = Math.max(0, Math.min(100, frac * 100)).toFixed(1) + "%";
    if (color) s.style.background = color;
    b.appendChild(s);
    return b;
  }

  // ---------- validation (mirrors data/schema.json) ----------
  function isInt(v) { return typeof v === "number" && Math.floor(v) === v; }
  function validate(d) {
    if (!d || d.schema !== "overlord-activity/1") return "unknown schema";
    if (!isInt(d.generated) || d.step !== 900) return "bad header";
    if (!d.names || typeof d.names.fights !== "object" || typeof d.names.zones !== "object" || typeof d.names.points !== "object") return "bad names";
    if (!Array.isArray(d.chars) || !Array.isArray(d.buckets) || !Array.isArray(d.sessions)) return "bad arrays";
    for (var i = 0; i < d.buckets.length; i++) {
      var b = d.buckets[i];
      if (!isInt(b.t) || (b.d !== 900 && b.d !== 3600) || !isInt(b.n) || typeof b.f !== "object" || typeof b.pz !== "object" || typeof b.cp !== "object") return "bad bucket " + i;
      for (var k in b.f) if (!Array.isArray(b.f[k]) || b.f[k].length !== 3) return "bad bucket front " + i;
    }
    for (i = 0; i < d.sessions.length; i++) if (!isInt(d.sessions[i].s) || !isInt(d.sessions[i].e)) return "bad session " + i;
    if (d.weekly != null) {
      var w = d.weekly;
      if (!Array.isArray(w.weeks) || !Array.isArray(w.factions) || !Array.isArray(w.guilds) || !Array.isArray(w.frontLast)) return "bad weekly";
    }
    return null;
  }

  function fetchJson(url) {
    return fetch(url, { cache: "no-cache", credentials: "omit" }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status);
      return r.json();
    });
  }

  function load() {
    return fetchJson("data/activity.json").then(function (d) {
      var err = validate(d);
      if (err) throw new Error("activity.json: " + err);
      if (d.sample) return { data: d, why: "flag" };
      return { data: d, why: null };
    }).catch(function (e) {
      return fetchJson("data/sample.json").then(function (d) {
        var err = validate(d);
        if (err) throw new Error("sample.json: " + err);
        d.sample = true;
        return { data: d, why: String(e && e.message || e) };
      });
    });
  }

  // ---------- aggregation ----------
  function aggFights(win) {
    var m = {}, totalEst = 0;
    D.buckets.forEach(function (b) {
      if (!inWin(b, win)) return;
      for (var k in b.f) {
        var e = b.f[k], a = m[k] || (m[k] = { key: k, sum: 0, n: 0, peak: 0, buckets: 0 });
        a.sum += e[0]; a.n += b.n; a.peak = Math.max(a.peak, e[1]); a.buckets++;
        totalEst += est(e[0]);
      }
    });
    var list = Object.keys(m).map(function (k) { return m[k]; });
    list.sort(function (a, b) { return b.sum - a.sum; });
    return { list: list, totalEst: totalEst };
  }
  function coverageSec(win) {
    var s = 0;
    D.buckets.forEach(function (b) { if (inWin(b, win)) s += b.n * 30; });
    return s;
  }
  function aggOwnZones(win) {
    var m = {};
    D.buckets.forEach(function (b) { if (!inWin(b, win)) return; for (var k in b.pz) m[k] = (m[k] || 0) + b.pz[k] * 30; });
    return Object.keys(m).map(function (k) { return { key: k, sec: m[k] }; }).sort(function (a, b) { return b.sec - a.sec; });
  }
  function rangeStats(from, to) {
    var r = { est: 0, sec: 0, hk: 0, hkKnown: false, cap: 0, sessions: 0, fights: {} };
    D.buckets.forEach(function (b) {
      if (b.t < from || b.t >= to) return;
      r.sec += b.n * 30;
      if (b.hk != null) { r.hk += b.hk; r.hkKnown = true; }
      for (var k in b.cp) r.cap += b.cp[k];
      for (var f in b.f) { var e = est(b.f[f][0]); r.est += e; r.fights[f] = (r.fights[f] || 0) + e; }
    });
    D.sessions.forEach(function (s) { if (s.s >= from && s.s < to) r.sessions++; });
    var top = null;
    for (var k in r.fights) if (!top || r.fights[k] > r.fights[top]) top = k;
    r.top = top;
    return r;
  }

  // ---------- sections ----------
  function renderMeta(why) {
    var banner = $("#banner");
    if (D.sample) {
      banner.hidden = false;
      clear(banner).appendChild(document.createTextNode("Sample data – not real recordings."));
      banner.appendChild(el("small", null, why === "flag"
        ? "The uploaded file is marked as sample data."
        : /HTTP 404/.test(why || "")
          ? "No uploaded activity file yet, so this page shows the built-in sample. It is replaced automatically after the first upload."
          : "The uploaded activity file could not be read (" + why + "), so this page shows the built-in sample."));
    }
    $("#meta").textContent = "Data saved " + dt(D.generated) + ". Times are shown in your local time zone: " + tzLabel() + ".";
  }

  function card(k, v, s) { return el("div", { cls: "card" }, el("div", { cls: "k" }, k), el("div", { cls: "v" }, v), s ? el("div", { cls: "s" }, s) : null); }

  function renderSummary() {
    var all = aggFights("all"), wk = aggFights("7");
    var first = D.buckets.length ? D.buckets.reduce(function (m, b) { return Math.min(m, b.t); }, Infinity) : null;
    var box = clear($("#summary"));
    box.appendChild(card("Est. HKs, last 7 days", nf0.format(wk.totalEst), "all fronts while you were online"));
    box.appendChild(card("Est. HKs, all time", nf0.format(all.totalEst), first ? "since " + dateOnly(first) : ""));
    box.appendChild(card("Hours recorded", nf1.format(coverageSec("all") / 3600), nf1.format(coverageSec("7") / 3600) + " h in the last 7 days"));
    box.appendChild(card("Sessions", nf0.format(D.sessions.length), D.chars.length + " character" + (D.chars.length === 1 ? "" : "s")));
    box.appendChild(card("Busiest front (all time)", all.list.length ? fightName(all.list[0].key) : "–", all.list.length ? fightKind(all.list[0].key) : ""));
  }

  function renderTop() {
    var a = aggFights(state.topWin), box = clear($("#top-table"));
    if (!a.list.length) box.appendChild(empty("Nothing recorded in this window."));
    else {
      var max = a.list[0].sum || 1;
      box.appendChild(table(["#", "Zone / front", "Type", "Est. HKs", "Share", "Avg 5-min fight size", "Est. HKs per hour", "Peak 5-min kills"],
        a.list.map(function (x, i) {
          return [i + 1, fightName(x.key), el("span", { cls: "kind" }, fightKind(x.key)), nf0.format(est(x.sum)), bar(x.sum / max),
            x.n ? nf1.format(x.sum / x.n) : "–", x.n ? nf1.format(x.sum / x.n * 12) : "–", nf0.format(x.peak)];
        }), [0, 3, 5, 6, 7]));
    }
    var oz = aggOwnZones(state.topWin), ob = clear($("#own-zones"));
    if (!oz.length) ob.appendChild(empty("No own-zone time recorded in this window."));
    else {
      var mx = oz[0].sec || 1;
      ob.appendChild(table(["Your zone", "Time there", ""], oz.map(function (z) {
        return [D.names.zones[z.key] || ("Map " + z.key), fmtHours(z.sec), bar(z.sec / mx, "#5ab0f0")];
      }), [1]));
    }
  }

  function heatColor(f) { // 0..1 -> dark olive to amber
    var a = [42, 42, 34], b = [224, 168, 58];
    var c = a.map(function (x, i) { return Math.round(x + (b[i] - x) * Math.sqrt(f)); });
    return "rgb(" + c.join(",") + ")";
  }

  function renderHeatmap() {
    var est7 = [], sec7 = [];
    for (var d = 0; d < 7; d++) { est7.push(new Array(24).fill(0)); sec7.push(new Array(24).fill(0)); }
    D.buckets.forEach(function (b) {
      if (!inWin(b, state.heatWin)) return;
      var dd = new Date(b.t * 1000), wd = weekdayIdx(dd), h = dd.getHours();
      est7[wd][h] += bucketEst(b);
      sec7[wd][h] += b.n * 30;
    });
    var metric = state.heatMetric, vals = [], max = 0;
    for (d = 0; d < 7; d++) {
      vals.push([]);
      for (var h = 0; h < 24; h++) {
        var v = null;
        if (sec7[d][h] > 0) v = metric === "rate" ? est7[d][h] / (sec7[d][h] / 3600) : metric === "total" ? est7[d][h] : sec7[d][h] / 3600;
        vals[d].push(v);
        if (v != null && v > max) max = v;
      }
    }
    var grid = el("div", { cls: "heat", role: "img", "aria-label": "Weekday by hour heatmap" });
    grid.appendChild(el("div"));
    for (h = 0; h < 24; h++) grid.appendChild(el("div", { cls: "lbl" }, h % 3 === 0 ? String(h).padStart(2, "0") : ""));
    var unit = metric === "rate" ? "est. HKs per recorded hour" : metric === "total" ? "est. HKs" : "hours recorded";
    for (d = 0; d < 7; d++) {
      grid.appendChild(el("div", { cls: "lbl rl" }, DAYS[d]));
      for (h = 0; h < 24; h++) {
        var val = vals[d][h], c = el("div", { cls: "c" });
        var range = DAYS[d] + " " + String(h).padStart(2, "0") + ":00–" + String((h + 1) % 24).padStart(2, "0") + ":00";
        if (val == null) { c.className = "c none"; c.title = range + ": not recorded"; }
        else {
          c.style.background = heatColor(max ? val / max : 0);
          c.title = range + ": " + (metric === "hours" ? nf1.format(val) : nf0.format(val)) + " " + unit + " (" + nf1.format(sec7[d][h] / 3600) + " h recorded, " + nf0.format(est7[d][h]) + " est. HKs)";
        }
        grid.appendChild(c);
      }
    }
    clear($("#heat-grid")).appendChild(grid);
    $("#heat-hint").textContent = "Rows are weekdays, columns are hours of the day in " + tzLabel() + ". " +
      (metric === "rate" ? "Per-hour rates divide by the time actually recorded in each cell, so lightly covered hours are not punished. " : "") +
      "Hatched cells were never recorded. Hover a cell for details.";
    var lg = clear($("#heat-legend"));
    lg.appendChild(el("span", null, "0 "));
    lg.appendChild(el("span", { cls: "ramp" }));
    lg.appendChild(el("span", null, " " + (metric === "hours" ? nf1.format(max) : nf0.format(max)) + " " + unit));
    lg.appendChild(el("span", null, el("span", { cls: "sw none" }), "not recorded"));
  }

  // generic SVG line chart. series: [{name,color,values:[number|null]}], labels: [string]
  function lineChart(node, labels, series, opts) {
    opts = opts || {};
    var W = opts.width || 900, H = opts.height || 260, L = 56, R = 12, T = 12, B = 30;
    var max = 0;
    series.forEach(function (s) { s.values.forEach(function (v) { if (v != null && v > max) max = v; }); });
    if (max <= 0) max = 1;
    var nice = Math.pow(10, Math.floor(Math.log10(max))), top = Math.ceil(max / nice) * nice;
    var svg = sv("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": opts.label || "chart" });
    var n = labels.length, xs = function (i) { return L + (n <= 1 ? 0 : i * (W - L - R) / (n - 1)); }, ys = function (v) { return T + (H - T - B) * (1 - v / top); };
    for (var g = 0; g <= 4; g++) {
      var gv = top * g / 4, y = ys(gv);
      svg.appendChild(sv("line", { x1: L, x2: W - R, y1: y, y2: y, "class": "grid" }));
      svg.appendChild(sv("text", { x: L - 6, y: y + 4, "text-anchor": "end" }, opts.fmt ? opts.fmt(gv) : nf0.format(gv)));
    }
    var step = Math.max(1, Math.ceil(n / (W < 700 ? 4 : 10)));
    labels.forEach(function (lb, i) {
      if (i % step === 0 || i === n - 1) svg.appendChild(sv("text", { x: xs(i), y: H - 8, "text-anchor": i === n - 1 && n > 1 ? "end" : i === 0 ? "start" : "middle" }, lb));
    });
    series.forEach(function (s) {
      var d = "", pen = false;
      s.values.forEach(function (v, i) {
        if (v == null) { pen = false; return; }
        d += (pen ? "L" : "M") + xs(i).toFixed(1) + " " + ys(v).toFixed(1) + " "; pen = true;
      });
      if (d) svg.appendChild(sv("path", { d: d, fill: "none", stroke: s.color, "stroke-width": 2, "stroke-linejoin": "round" }));
      s.values.forEach(function (v, i) {
        if (v == null) return;
        var c = sv("circle", { cx: xs(i), cy: ys(v), r: 2.6, fill: s.color });
        c.appendChild(sv("title", {}, s.name + " – " + labels[i] + ": " + (opts.fmt ? opts.fmt(v) : nf0.format(v))));
        svg.appendChild(c);
      });
    });
    clear(node).appendChild(svg);
  }

  function barChart(node, labels, values, opts) {
    opts = opts || {};
    var W = 900, H = opts.height || 200, L = 56, R = 12, T = 12, B = 30;
    var max = 0; values.forEach(function (v) { if (v != null && v > max) max = v; });
    if (max <= 0) max = 1;
    var nice = Math.pow(10, Math.floor(Math.log10(max))), top = Math.ceil(max / nice) * nice;
    var svg = sv("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": opts.label || "bar chart" });
    var n = labels.length, bw = (W - L - R) / Math.max(1, n), ys = function (v) { return T + (H - T - B) * (1 - v / top); };
    for (var g = 0; g <= 4; g++) {
      var y = ys(top * g / 4);
      svg.appendChild(sv("line", { x1: L, x2: W - R, y1: y, y2: y, "class": "grid" }));
      svg.appendChild(sv("text", { x: L - 6, y: y + 4, "text-anchor": "end" }, opts.fmt ? opts.fmt(top * g / 4) : nf0.format(top * g / 4)));
    }
    var step = Math.max(1, Math.ceil(n / 10));
    values.forEach(function (v, i) {
      var x = L + i * bw;
      if (v != null && v > 0) {
        var r = sv("rect", { x: x + bw * 0.12, y: ys(v), width: Math.max(1, bw * 0.76), height: ys(0) - ys(v), rx: 2, fill: (opts.colors && opts.colors[i]) || opts.color || "#e0a83a" });
        r.appendChild(sv("title", {}, labels[i] + ": " + (opts.fmt ? opts.fmt(v) : nf0.format(v))));
        svg.appendChild(r);
      }
      if (i % step === 0 || i === n - 1) svg.appendChild(sv("text", { x: x + bw / 2, y: H - 8, "text-anchor": "middle" }, labels[i]));
    });
    clear(node).appendChild(svg);
  }

  function last30Days() {
    var end = localDayStart(D.generated), days = [];
    for (var i = 29; i >= 0; i--) {
      var d = new Date(end * 1000); d.setDate(d.getDate() - i);
      var s = Math.floor(d.getTime() / 1000), e = new Date(d.getTime()); e.setDate(e.getDate() + 1);
      days.push({ s: s, e: Math.floor(e.getTime() / 1000), label: new Date(s * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" }) });
    }
    return days;
  }

  function renderTrends() {
    var days = last30Days(), from = days[0].s, to = days[days.length - 1].e;
    var perDay = {}, secDay = {};
    D.buckets.forEach(function (b) {
      if (b.t < from || b.t >= to) return;
      var k = dayKey(b.t);
      secDay[k] = (secDay[k] || 0) + b.n * 30;
      for (var f in b.f) { var m = perDay[f] || (perDay[f] = {}); m[k] = (m[k] || 0) + est(b.f[f][0]); }
    });
    var keys = Object.keys(perDay).map(function (f) {
      var t = 0; for (var k in perDay[f]) t += perDay[f][k]; return { f: f, t: t };
    }).sort(function (a, b) { return b.t - a.t; }).slice(0, 8);
    var node = $("#trend-chart"), lg = clear($("#trend-legend"));
    if (!keys.length) { clear(node).appendChild(empty("Nothing recorded in the last 30 days.")); return; }
    var series = keys.map(function (x, i) {
      return { name: fightName(x.f), color: SERIES[i % SERIES.length], values: days.map(function (d) {
        var k = dayKey(d.s), sec = secDay[k] || 0;
        if (!sec) return null;
        var v = (perDay[x.f][k] || 0);
        return state.trendMetric === "rate" ? v / (sec / 3600) : v;
      }) };
    });
    lineChart(node, days.map(function (d) { return d.label; }), series, { label: "Estimated HKs per day by zone" });
    series.forEach(function (s) { lg.appendChild(el("span", null, (function () { var w = el("span", { cls: "sw" }); w.style.background = s.color; return w; })(), s.name)); });
  }

  function weekBounds() {
    var cs = null;
    if (D.weekly && D.weekly.weeks.length) cs = D.weekly.weeks.reduce(function (m, w) { return Math.max(m, w.cs); }, 0);
    if (cs) {
      var start = cs + Math.floor((D.generated - cs) / WEEK) * WEEK;
      return { start: start, label: "Weeks follow Overlord's campaign week, which starts " + new Date(start * 1000).toLocaleString(undefined, { weekday: "long", hour: "2-digit", minute: "2-digit" }) + " your time." };
    }
    var d = new Date(D.generated * 1000); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() - weekdayIdx(d));
    return { start: Math.floor(d.getTime() / 1000), label: "Weeks start Monday 00:00 your time." };
  }

  function delta(a, b, fmt) {
    if (a == null || b == null) return "–";
    var diff = a - b, span = el("span", { cls: diff > 0 ? "up" : diff < 0 ? "down" : "" });
    var pct = b ? " (" + (diff >= 0 ? "+" : "") + nf0.format(diff / b * 100) + "%)" : "";
    span.textContent = (diff > 0 ? "+" : diff < 0 ? "−" : "±") + (fmt || nf0.format)(Math.abs(diff)) + pct;
    return span;
  }

  function renderWeek() {
    var wb = weekBounds(), tw = rangeStats(wb.start, wb.start + WEEK), lw = rangeStats(wb.start - WEEK, wb.start);
    $("#week-hint").textContent = wb.label + " This week: " + dateOnly(wb.start) + " until the data was saved; last week: " + dateOnly(wb.start - WEEK) + " – " + dateOnly(wb.start - 1) + ".";
    var rate = function (r) { return r.sec ? r.est / (r.sec / 3600) : null; };
    var f1 = function (v) { return nf1.format(v); };
    var rows = [
      ["Est. HKs (all fronts)", nf0.format(tw.est), nf0.format(lw.est), delta(tw.est, lw.est)],
      ["Hours recorded", nf1.format(tw.sec / 3600), nf1.format(lw.sec / 3600), delta(tw.sec / 3600, lw.sec / 3600, f1)],
      ["Est. HKs per recorded hour", dash(rate(tw)), dash(rate(lw)), delta(rate(tw), rate(lw))],
      ["Sessions started", nf0.format(tw.sessions), nf0.format(lw.sessions), delta(tw.sessions, lw.sessions)],
      ["Your own HKs", tw.hkKnown ? nf0.format(tw.hk) : "–", lw.hkKnown ? nf0.format(lw.hk) : "–", delta(tw.hkKnown ? tw.hk : null, lw.hkKnown ? lw.hk : null)],
      ["Captures seen", nf0.format(tw.cap), nf0.format(lw.cap), delta(tw.cap, lw.cap)],
      ["Busiest zone / front", tw.top ? fightName(tw.top) : "–", lw.top ? fightName(lw.top) : "–", ""]
    ];
    if (D.weekly) {
      var wk = {}; D.weekly.weeks.forEach(function (w) { wk[w.cs] = w; });
      var a = wk[wb.start], b = wk[wb.start - WEEK];
      rows.push(["Overlord top-100 HKs (network; this week still running)", a ? nf0.format(a.total) : "–", b ? nf0.format(b.total) : "–", delta(a ? a.total : null, b ? b.total : null)]);
    }
    clear($("#week-table")).appendChild(table(["", "This week", "Last week", "Change"], rows, [1, 2, 3]));
  }

  function sessionEst(s) {
    var from = s.s - (s.s % 900), t = 0, fights = {};
    D.buckets.forEach(function (b) {
      if (b.t < from || b.t >= s.e) return;
      for (var f in b.f) { var e = est(b.f[f][0]); t += e; fights[f] = (fights[f] || 0) + e; }
    });
    var top = null; for (var k in fights) if (!top || fights[k] > fights[top]) top = k;
    return { est: t, top: top };
  }

  function renderSessions() {
    var list = D.sessions.slice().sort(function (a, b) { return b.s - a.s; });
    var box = clear($("#session-table")), more = $("#session-more");
    if (!list.length) { box.appendChild(empty("No sessions recorded.")); more.hidden = true; return; }
    var shown = state.showAllSessions ? list : list.slice(0, 25);
    box.appendChild(table(["Date", "Start", "End", "Duration", "Character", "Est. HKs", "Busiest"], shown.map(function (s) {
      var x = sessionEst(s);
      return [dateOnly(s.s), timeOnly(s.s), timeOnly(s.e), fmtDur(s.e - s.s), D.chars[s.ch] != null ? D.chars[s.ch] : "–", nf0.format(x.est), x.top ? fightName(x.top) : "–"];
    }), [5]));
    more.hidden = list.length <= 25 || state.showAllSessions;
    more.textContent = "Show all " + list.length + " sessions";
  }

  function renderCoverage() {
    var box = clear($("#coverage-cards"));
    var sess = function (win) { var s = 0, from = windowStart(win); D.sessions.forEach(function (x) { if (x.e >= from && x.s <= D.generated) s += x.e - Math.max(x.s, from); }); return s; };
    [["7", "Last 7 days"], ["30", "Last 30 days"], ["all", "All time"]].forEach(function (w) {
      box.appendChild(card(w[1], nf1.format(coverageSec(w[0]) / 3600) + " h", "recorded · " + nf1.format(sess(w[0]) / 3600) + " h in sessions"));
    });
    var old = D.buckets.filter(function (b) { return b.d === 3600; }).length;
    if (old) box.appendChild(card("Compacted hours", nf0.format(old), "older than 30 days, kept as hourly totals"));
    var days = last30Days(), sec = {};
    D.buckets.forEach(function (b) { if (b.t >= days[0].s && b.t < days[days.length - 1].e) { var k = dayKey(b.t); sec[k] = (sec[k] || 0) + b.n * 30; } });
    barChart($("#coverage-chart"), days.map(function (d) { return d.label; }), days.map(function (d) { return (sec[dayKey(d.s)] || 0) / 3600; }),
      { label: "Hours recorded per day, last 30 days", color: "#5ab0f0", fmt: function (v) { return nf1.format(v) + " h"; } });
  }

  function renderWeekly() {
    var W = D.weekly;
    $("#weekly-empty").hidden = !!W;
    $("#weekly-body").hidden = !W;
    if (!W) return;
    // W
    var weeks = W.weeks.slice().sort(function (a, b) { return a.cs - b.cs; });
    barChart($("#weeks-chart"), weeks.map(function (w) { return new Date(w.cs * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" }); }),
      weeks.map(function (w) { return w.total; }), { label: "Top-100 HKs per week", colors: weeks.map(function (w) { return w.src === "live" ? "#5ab0f0" : "#e0a83a"; }) });
    clear($("#weeks-table")).appendChild(weeks.length ? table(
      ["Week starting", "Source", "Top-100 HKs", "Players", "Captures", "Zones captured", "Alliance HKs", "Horde HKs", "Best player HKs"],
      weeks.slice().reverse().map(function (w) {
        return [dt(w.cs), w.src === "live" ? "live (running week)" : w.src === "history" ? "history (archive)" : w.src, nf0.format(w.total), nf0.format(w.players),
          dash(w.cap), dash(w.zones), w.alli ? nf0.format(w.alli) : "–", w.horde ? nf0.format(w.horde) : "–", nf0.format(w.topKills)];
      }), [2, 3, 4, 5, 6, 7, 8]) : empty("No weekly records."));
    // F
    var fs = W.factions.slice().sort(function (a, b) { return a.t - b.t; });
    var fnode = $("#faction-chart"), flg = clear($("#faction-legend"));
    if (fs.length) {
      var labels = fs.map(function (f) { return new Date(f.t * 1000).toLocaleString(undefined, { weekday: "short", hour: "2-digit", minute: "2-digit" }) + (f.src === "cache" ? " (cache)" : ""); });
      var ser = [{ name: "Alliance", color: "#4a90e2", values: fs.map(function (f) { return f.a; }) },
                 { name: "Horde", color: "#d9534f", values: fs.map(function (f) { return f.h; }) },
                 { name: "Unknown faction", color: "#9aa3b2", values: fs.map(function (f) { return f.u; }) }];
      lineChart(fnode, labels, ser, { width: 520, height: 300, label: "Faction HK totals over the running week" });
      ser.forEach(function (s) { var w = el("span", { cls: "sw" }); w.style.background = s.color; flg.appendChild(el("span", null, w, s.name)); });
      var lastF = fs[fs.length - 1];
      flg.appendChild(el("span", null, "Latest (" + lastF.src + "): Alliance " + nf0.format(lastF.a) + " · Horde " + nf0.format(lastF.h) + " · unknown " + dash(lastF.u) + " · players " + dash(lastF.n)));
    } else clear(fnode).appendChild(empty("No faction samples."));
    // G
    var gl = W.guilds.slice().sort(function (a, b) { return a.rank - b.rank; });
    var gmax = gl.length ? Math.max.apply(null, gl.map(function (g) { return g.kills; })) || 1 : 1;
    clear($("#guild-table")).appendChild(gl.length ? table(["#", "Guild", "Faction", "HKs", ""], gl.map(function (g) {
      return [g.rank, g.name, g.faction || "–", nf0.format(g.kills), bar(g.kills / gmax, g.faction === "Alliance" ? "#4a90e2" : g.faction === "Horde" ? "#d9534f" : null)];
    }), [0, 3]) : empty("No guild ranking."));
    // M
    var mb = clear($("#me-box"));
    if (W.me) {
      var m = W.me, pct = m.players ? m.rank / m.players * 100 : null;
      mb.appendChild(el("dl", { cls: "kv" },
        el("dt", null, "Week starting"), el("dd", null, dt(m.cs)),
        el("dt", null, "Rank"), el("dd", null, nf0.format(m.rank) + " of " + nf0.format(m.players) + (pct != null ? " (top " + nf1.format(pct) + "%)" : "")),
        el("dt", null, "HKs"), el("dd", null, nf0.format(m.kills)),
        el("dt", null, "Killing blows"), el("dd", null, dash(m.kb))));
    } else mb.appendChild(empty("Your character was not found in this week's ranking."));
    // V
    var vb = clear($("#victory-box"));
    if (W.victory) {
      var v = W.victory, fac = v.faction ? v.faction.charAt(0) + v.faction.slice(1).toLowerCase() : "–";
      vb.appendChild(el("dl", { cls: "kv" },
        el("dt", null, "Front"), el("dd", null, fightName(v.front)),
        el("dt", null, "Winner"), el("dd", null, fac),
        el("dt", null, "Allied kills"), el("dd", null, nf0.format(v.ally)),
        el("dt", null, "Enemy kills"), el("dd", null, nf0.format(v.enemy)),
        el("dt", null, "Total kills"), el("dd", null, nf0.format(v.total))));
    } else vb.appendChild(empty("No front victory snapshot."));
    // L
    var latest = {};
    W.frontLast.forEach(function (e) { if (!latest[e.front] || e.t > latest[e.front]) latest[e.front] = e.t; });
    var lk = Object.keys(latest).sort(function (a, b) { return latest[b] - latest[a]; });
    clear($("#front-last")).appendChild(lk.length ? table(["Front", "Last seen active", "Ago"], lk.map(function (k) {
      var ago = D.generated - latest[k];
      return [fightName(k), dt(latest[k]), ago < 3600 ? nf0.format(Math.max(0, ago / 60)) + " min" : ago < 2 * DAY ? nf1.format(ago / 3600) + " h" : nf1.format(ago / DAY) + " days"];
    })) : empty("No front activity times."));
  }

  function renderAll() {
    renderSummary(); renderTop(); renderHeatmap(); renderTrends(); renderWeek(); renderSessions(); renderCoverage(); renderWeekly();
  }

  function wireControls() {
    document.querySelectorAll(".seg[data-group]").forEach(function (g) {
      var key = g.getAttribute("data-group");
      var sync = function () { g.querySelectorAll("button").forEach(function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-v") === state[key])); }); };
      g.addEventListener("click", function (ev) {
        var b = ev.target.closest("button"); if (!b) return;
        state[key] = b.getAttribute("data-v"); sync();
        if (key === "topWin") renderTop(); else if (key.indexOf("heat") === 0) renderHeatmap(); else if (key === "trendMetric") renderTrends();
      });
      sync();
    });
    $("#session-more").addEventListener("click", function () { state.showAllSessions = true; renderSessions(); });
  }

  function start() {
    wireControls();
    load().then(function (r) {
      D = r.data;
      window.OA_DATA_INFO = { sample: !!D.sample, source: D.source, buckets: D.buckets.length, fallbackReason: r.why };
      renderMeta(r.why);
      var named = D.chars.some(function (c) { return !/^Character \d+$|^multiple$|^\?$/.test(c); });
      if (named) document.querySelector(".site-footer p:nth-child(2)").textContent = "Privacy: the weekly best player's name is never published. Guild names come from Overlord's public weekly ranking.";
      renderAll();
      document.documentElement.setAttribute("data-ready", "1");
    }).catch(function (e) {
      $("#meta").textContent = "Could not load any data (" + (e && e.message || e) + ").";
      document.documentElement.setAttribute("data-ready", "error");
    });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
