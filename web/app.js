// pwbridge-tab shared state and PowerShell terminal.
//
// The token arrives in the query string because that is the only way the
// launcher can hand it to a fresh tab. It is moved into memory and stripped
// from the address bar immediately so it does not linger in browser history.

'use strict';

const PwBridge = (function () {
  const $ = (id) => document.getElementById(id);

  function readToken() {
    const params = new URLSearchParams(window.location.search);
    const fromUrl = params.get('token');
    if (fromUrl) {
      try {
        sessionStorage.setItem('pwbridge-token', fromUrl);
      } catch (e) {
        /* private mode: keep it in memory only */
      }
      window.history.replaceState({}, document.title, window.location.pathname);
      return fromUrl;
    }
    try {
      return sessionStorage.getItem('pwbridge-token') || '';
    } catch (e) {
      return '';
    }
  }

  const token = readToken();

  async function api(path, options) {
    const opts = Object.assign({ method: 'GET' }, options || {});
    opts.headers = Object.assign({ 'X-PwBridge-Token': token }, opts.headers || {});
    if (opts.body && typeof opts.body !== 'string') {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.body);
    }
    const response = await fetch(path, opts);
    return response;
  }

  async function apiJson(path, options) {
    const response = await api(path, options);
    let body = null;
    try {
      body = await response.json();
    } catch (e) {
      body = null;
    }
    if (!response.ok) {
      const message = (body && body.error) || `Request failed (${response.status})`;
      const hint = (body && body.hint) || '';
      const error = new Error(hint ? `${message} ${hint}` : message);
      error.status = response.status;
      throw error;
    }
    return body;
  }

  return { $, token, api, apiJson };
})();

(function terminal() {
  const $ = PwBridge.$;
  const out = $('out');
  const wsStatus = $('ws-status');
  const health = $('health');
  const history = [];
  let historyIndex = -1;
  let socket = null;

  function setPill(element, text, kind) {
    element.textContent = text;
    element.className = `pill ${kind}`;
  }

  function append(text, cls) {
    const atBottom = out.scrollHeight - out.scrollTop - out.clientHeight < 40;
    const line = document.createElement('div');
    if (cls) line.className = cls;
    line.textContent = text;
    out.appendChild(line);
    while (out.childElementCount > 5000) out.removeChild(out.firstChild);
    if (atBottom) out.scrollTop = out.scrollHeight;
  }

  function connect() {
    if (socket && socket.readyState <= WebSocket.OPEN) return;
    const url = `ws://${window.location.host}/?token=${encodeURIComponent(PwBridge.token)}`;
    setPill(wsStatus, 'connecting', 'warn');
    try {
      socket = new WebSocket(url);
    } catch (e) {
      append(`Could not open a connection: ${e.message}`, 'stderr');
      setPill(wsStatus, 'disconnected', 'bad');
      return;
    }

    socket.onopen = () => setPill(wsStatus, 'connected', 'ok');
    socket.onclose = () => setPill(wsStatus, 'disconnected', 'bad');
    socket.onerror = () => {
      append('Connection error. The bridge may have stopped.', 'stderr');
      setPill(wsStatus, 'disconnected', 'bad');
    };
    socket.onmessage = (event) => {
      let message;
      try {
        message = JSON.parse(event.data);
      } catch (e) {
        append(event.data);
        return;
      }
      const cls = message.type === 'stderr' ? 'stderr' : message.type === 'info' ? 'info' : null;
      append(message.data, cls);
    };
  }

  function disconnect() {
    if (socket) {
      socket.close();
      socket = null;
    }
  }

  function send() {
    const input = $('cmd');
    const text = input.value;
    if (!text.trim()) return;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      append('Not connected. Press Connect first.', 'stderr');
      return;
    }
    append(`PS> ${text}`, 'echo');
    socket.send(JSON.stringify({ type: 'exec', data: text }));
    history.push(text);
    if (history.length > 200) history.shift();
    historyIndex = history.length;
    input.value = '';
  }

  function recallHistory(delta) {
    if (!history.length) return;
    historyIndex = Math.min(history.length, Math.max(0, historyIndex + delta));
    $('cmd').value = historyIndex >= history.length ? '' : history[historyIndex];
  }

  async function refreshHealth() {
    try {
      const body = await PwBridge.apiJson('/api/health');
      setPill(health, `bridge v${body.version}`, 'ok');
      $('shell-name').textContent = body.shellName ? `shell: ${body.shellName}` : '';
      document.dispatchEvent(new CustomEvent('pwbridge-health', { detail: body }));
    } catch (e) {
      setPill(health, e.status === 401 ? 'unauthorized' : 'bridge offline', 'bad');
      if (e.status === 401) {
        append('This tab has no valid token. Reopen pwbridge-tab from its desktop shortcut.', 'stderr');
      }
    }
  }

  $('connect').addEventListener('click', connect);
  $('disconnect').addEventListener('click', disconnect);
  $('clear').addEventListener('click', () => { out.textContent = ''; });
  $('send').addEventListener('click', send);

  $('cmd').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      send();
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      recallHistory(-1);
    } else if (event.key === 'ArrowDown') {
      event.preventDefault();
      recallHistory(1);
    } else if (event.key === 'c' && event.ctrlKey && !window.getSelection().toString()) {
      if (socket && socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ type: 'interrupt' }));
      }
    }
  });

  document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      const target = tab.getAttribute('aria-controls');
      document.querySelectorAll('.tab').forEach((t) => {
        const active = t === tab;
        t.classList.toggle('active', active);
        t.setAttribute('aria-selected', String(active));
      });
      document.querySelectorAll('.panel').forEach((panel) => {
        panel.classList.toggle('active', panel.id === target);
      });
      document.dispatchEvent(new CustomEvent('pwbridge-tab-changed', { detail: { panel: target } }));
    });
  });

  $('warning-dismiss').addEventListener('click', () => $('warning').classList.add('hidden'));

  $('btn-stop-server').addEventListener('click', async () => {
    if (!window.confirm('Stop the pwbridge-tab bridge? The tab will stop working until you start it again.')) return;
    try {
      await PwBridge.apiJson('/api/control/shutdown', { method: 'POST' });
    } catch (e) {
      /* the socket drops as the server exits, which is expected */
    }
    disconnect();
    setPill(health, 'bridge stopped', 'bad');
    append('Bridge stopped. Use the desktop shortcut to start it again.', 'info');
  });

  const dialog = $('logs-dialog');

  $('btn-diagnostics').addEventListener('click', async () => {
    $('logs-body').textContent = 'Loading...';
    if (typeof dialog.showModal === 'function') dialog.showModal();
    try {
      const body = await PwBridge.apiJson('/api/logs?tail=300');
      $('logs-body').textContent = body.lines || '(log is empty)';
    } catch (e) {
      $('logs-body').textContent = `Could not read the log: ${e.message}`;
    }
  });

  $('logs-close').addEventListener('click', () => dialog.close());

  $('logs-download').addEventListener('click', async () => {
    try {
      const response = await PwBridge.api('/api/diagnostics');
      if (!response.ok) throw new Error(`Request failed (${response.status})`);
      const blob = await response.blob();
      const link = document.createElement('a');
      link.href = URL.createObjectURL(blob);
      link.download = `pwbridge-diagnostics-${Date.now()}.zip`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(link.href), 10000);
    } catch (e) {
      $('logs-body').textContent = `Could not build the diagnostics zip: ${e.message}`;
    }
  });

  refreshHealth();
  setInterval(refreshHealth, 15000);
  connect();
})();
