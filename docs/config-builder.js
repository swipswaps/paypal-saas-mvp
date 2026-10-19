(function () {
  'use strict';
  var KEY = 'ppsaas.brand';
  var DEFAULTS = {
    BRAND_NAME: 'Demo SaaS',
    BRAND_TAGLINE: 'Sandbox subscription billing with PayPal Server SDK and Flask.',
    TIER_BASIC_NAME: 'Basic Tier',
    TIER_BASIC_PRICE: '9.99',
    TIER_PRO_NAME: 'Pro Tier',
    TIER_PRO_PRICE: '29.99',
    CURRENCY_CODE: 'USD',
    CURRENCY_SYMBOL: '$',
    BILLING_INTERVAL: 'MONTH'
  };
  var ORDER = ['BRAND_NAME','BRAND_TAGLINE','TIER_BASIC_NAME','TIER_BASIC_PRICE',
               'TIER_PRO_NAME','TIER_PRO_PRICE','CURRENCY_CODE','CURRENCY_SYMBOL','BILLING_INTERVAL'];

  function load() {
    try {
      var raw = localStorage.getItem(KEY);
      if (raw) return Object.assign({}, DEFAULTS, JSON.parse(raw));
    } catch (e) {}
    return Object.assign({}, DEFAULTS);
  }
  function save(s) { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (e) {} }

  function envSnippet(s) {
    var lines = ['# White-label overrides — append to .env'];
    ORDER.forEach(function (k) { lines.push(k + '=' + s[k]); });
    return lines.join('\n');
  }
  function nextSteps() {
    return [
      '# After appending the snippet to .env:',
      '#',
      '# 1. Re-register plans with the new prices & names:',
      'python setup_plans.py',
      '#',
      '# 2. Copy the printed PLAN_ID_BASIC and PLAN_ID_PRO into .env',
      '#',
      '# 3. Restart the backend:',
      'docker compose up -d --build',
      '#',
      '# Then open http://localhost:5000 — the new branding and tiers appear.'
    ].join('\n');
  }

  function bind() {
    var form = document.getElementById('cfg-form');
    if (!form) return;
    var state = load();
    ORDER.forEach(function (k) {
      var el = form.elements[k];
      if (el) el.value = state[k];
    });

    form.addEventListener('submit', function (e) {
      e.preventDefault();
      ORDER.forEach(function (k) { if (form.elements[k]) state[k] = form.elements[k].value; });
      save(state);
      document.getElementById('cfg-env').textContent = envSnippet(state);
      document.getElementById('cfg-next').textContent = nextSteps();
      document.getElementById('cfg-output').style.display = 'block';
    });

    var reset = document.getElementById('cfg-reset');
    if (reset) reset.addEventListener('click', function () {
      state = Object.assign({}, DEFAULTS);
      ORDER.forEach(function (k) { if (form.elements[k]) form.elements[k].value = state[k]; });
      save(state);
      document.getElementById('cfg-output').style.display = 'none';
    });

    var copy = document.getElementById('cfg-copy');
    if (copy) copy.addEventListener('click', function () {
      var txt = document.getElementById('cfg-env').textContent;
      navigator.clipboard.writeText(txt).then(function () {
        copy.textContent = 'Copied';
        setTimeout(function () { copy.textContent = 'Copy to clipboard'; }, 1500);
      });
    });

    var dl = document.getElementById('cfg-download');
    if (dl) dl.addEventListener('click', function () {
      var txt = document.getElementById('cfg-env').textContent + '\n\n' + document.getElementById('cfg-next').textContent;
      var blob = new Blob([txt], { type: 'text/plain' });
      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'white-label.env.txt';
      a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();
})();
