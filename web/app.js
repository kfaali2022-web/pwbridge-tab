// pwbridge-tab client. Connects to the local PowerShell WebSocket bridge.
(function () {
  const $ = (id) => document.getElementById(id);
  const out = $('out');
  const status = $('status');
  let ws = null;

  function setStatus(text, ok) {
    status.textContent = text;
    status.className = ok ? 'ok' : 'bad';
  }

  function append(text, cls) {
    const span = document.createElement('span');
    if (cls) span.className = cls;
    span.textContent = text + '\n';
    out.appendChild(span);
    out.scrollTop = out.scrollHeight;
  }

  function connect() {
    let url = $('ws').value.trim();
    const token = $('token').value.trim();
    if (token) url += (url.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(token);
    try {
      ws = new WebSocket(url);
    } catch (e) {
      append('Bad WS URL: ' + e.message, 'stderr');
      return;
    }
    setStatus('connecting...', false);
    ws.onopen = () => setStatus('connected', true);
    ws.onclose = () => setStatus('disconnected', false);
    ws.onerror = () => append('WebSocket error. Is the server running?', 'stderr');
    ws.onmessage = (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { append(ev.data); return; }
      append(msg.data, msg.type === 'stderr' ? 'stderr' : null);
    };
  }

  function disconnect() {
    if (ws) { ws.close(); ws = null; }
  }

  function send() {
    const cmd = $('cmd');
    const text = cmd.value;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      append('Not connected.', 'stderr');
      return;
    }
    append('PS> ' + text);
    ws.send(JSON.stringify({ type: 'exec', data: text }));
    cmd.value = '';
  }

  $('connect').addEventListener('click', connect);
  $('disconnect').addEventListener('click', disconnect);
  $('cmd').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); send(); }
    if (e.key === 'c' && e.ctrlKey && ws) { ws.send(JSON.stringify({ type: 'interrupt' })); }
  });
})();
