(function () {
  'use strict';
  var HOSTS = ['localhost', '127.0.0.1', '0.0.0.0'];
  var PORTS = [5000, 5001, 5002, 8000, 8080, 3000];
  var TIMEOUT = 2000;
  var KEY_LASTGOOD = 'ppsaas.lastGoodEndpoint';

  function fetchT(url, opts, ms) {
    return new Promise(function (resolve) {
      var c = new AbortController();
      var t = setTimeout(function () { c.abort(); }, ms);
      fetch(url, Object.assign({}, opts, { signal: c.signal }))
        .then(function (r) { clearTimeout(t); resolve({ ok: true, response: r }); })
        .catch(function (e) { clearTimeout(t); resolve({ ok: false, error: e }); });
    });
  }

  function probeOne(host, port) {
    var base = 'http://' + host + ':' + port;
    return fetchT(base + '/health', { mode: 'no-cors' }, TIMEOUT).then(function (nc) {
      if (!nc.ok) return { host: host, port: port, base: base, status: 'free' };
      return fetchT(base + '/health', { mode: 'cors' }, TIMEOUT).then(function (cors) {
        if (!cors.ok) return { host: host, port: port, base: base, status: 'other', detail: 'TCP up, CORS blocked (not our app)' };
        return cors.response.json().then(function (j) {
          if (j && j.status === 'healthy') return { host: host, port: port, base: base, status: 'ours', payload: j };
          return { host: host, port: port, base: base, status: 'other', detail: 'JSON but not our schema', payload: j };
        }).catch(function () {
          return { host: host, port: port, base: base, status: 'other', detail: 'Response not JSON' };
        });
      });
    });
  }

  function probeAll(onEach) {
    var all = [];
    var chain = Promise.resolve();
    HOSTS.forEach(function (h) {
      PORTS.forEach(function (p) {
        chain = chain.then(function () {
          return probeOne(h, p).then(function (r) { all.push(r); if (onEach) onEach(r, all); });
        });
      });
    });
    return chain.then(function () {
      var ours = all.filter(function (r) { return r.status === 'ours'; });
      if (ours.length > 0) { try { localStorage.setItem(KEY_LASTGOOD, ours[0].base); } catch (e) {} }
      return all;
    });
  }

  function getLastGood() { try { return localStorage.getItem(KEY_LASTGOOD); } catch (e) { return null; } }
  function clearLastGood() { try { localStorage.removeItem(KEY_LASTGOOD); } catch (e) {} }

    // Detect the "localhost free but 127.0.0.1 ours" browser quirk.
  // Returns null if no quirk, otherwise the working 127.0.0.1 endpoint.
  function quirkNote(results) {
    var byPort = {};
    results.forEach(function (r) { (byPort[r.port] = byPort[r.port] || {})[r.host] = r; });
    var hits = [];
    Object.keys(byPort).forEach(function (port) {
      var group = byPort[port];
      if (group['localhost'] && group['localhost'].status === 'free' &&
          group['127.0.0.1'] && group['127.0.0.1'].status === 'ours') {
        hits.push(group['127.0.0.1'].base);
      }
    });
    return hits.length > 0 ? hits[0] : null;
  }

window.PPSaaSProbe = {
    probeAll: probeAll,
    getLastGood: getLastGood,
    clearLastGood: clearLastGood,
    HOSTS: HOSTS,
    PORTS: PORTS,
    quirkNote: quirkNote
  };
})();
