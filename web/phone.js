// pwbridge-tab phone tab.
//
// Two mirroring paths, in order of reliability:
//   1. Native scrcpy, launched by the bridge. Best quality, works on Android 16.
//   2. In-browser preview: polled `adb exec-out screencap` frames plus tap,
//      swipe, key and text injection through `adb shell input`. Low frame rate
//      but it needs nothing beyond adb, so it is the dependable fallback.
// A ws-scrcpy server the tester already runs is detected and can be embedded,
// but pwbridge-tab never installs or requires one.

'use strict';

(function phone() {
  const $ = PwBridge.$;

  const screen = $('phone-screen');
  const placeholder = $('phone-placeholder');
  const stateChip = $('phone-state');
  const message = $('phone-message');
  const picker = $('phone-picker');
  const frame = $('wsscrcpy-frame');

  let previewRunning = false;
  let previewToken = 0;
  let deviceStatus = 'unknown';
  let deviceSize = { width: 0, height: 0 };
  let pointerStart = null;
  let currentObjectUrl = null;

  function setChip(text, kind) {
    stateChip.textContent = text;
    stateChip.className = `pill ${kind}`;
  }

  function setMessage(text, kind) {
    message.textContent = text || '';
    message.className = `notice${kind ? ' ' + kind : ''}`;
  }

  function setControlsEnabled(enabled) {
    document.querySelectorAll('.controls button, .controls input').forEach((element) => {
      if (element.id === 'wsscrcpy-embed' || element.id === 'wsscrcpy-close') return;
      element.disabled = !enabled;
    });
    $('phone-scrcpy').disabled = !enabled;
    $('phone-preview-toggle').disabled = !enabled;
  }

  function renderInfo(info) {
    const list = $('phone-info');
    list.textContent = '';
    if (!info) return;
    const rows = [
      ['Model', info.Model],
      ['Android', info.AndroidVersion],
      ['SDK', info.Sdk],
      ['Screen', info.Width && info.Height ? `${info.Width} x ${info.Height}` : '']
    ];
    rows.forEach(([label, value]) => {
      if (!value) return;
      const dt = document.createElement('dt');
      dt.textContent = label;
      const dd = document.createElement('dd');
      dd.textContent = value;
      list.appendChild(dt);
      list.appendChild(dd);
    });
    if (info.Width && info.Height) {
      deviceSize = { width: info.Width, height: info.Height };
    }
  }

  async function refreshDevices() {
    setChip('checking', 'warn');
    try {
      const body = await PwBridge.apiJson('/api/android/devices');
      deviceStatus = body.status;
      renderInfo(body.info);

      const authorized = (body.devices || []).filter((d) => d.authorized);
      if (body.status === 'multiple' && authorized.length > 1) {
        picker.textContent = '';
        authorized.forEach((device) => {
          const option = document.createElement('option');
          option.value = device.serial;
          option.textContent = device.model || device.serial;
          picker.appendChild(option);
        });
        picker.classList.remove('hidden');
      } else {
        picker.classList.add('hidden');
      }

      if (body.status === 'ready') {
        setChip('phone ready', 'ok');
        setMessage(body.message, 'good');
        setControlsEnabled(true);
      } else {
        setChip(body.status, 'bad');
        setMessage(`${body.message} ${body.hint || ''}`.trim(), 'error');
        setControlsEnabled(false);
        stopPreview();
      }
      return body.status;
    } catch (e) {
      deviceStatus = 'error';
      setChip('error', 'bad');
      setMessage(e.message, 'error');
      setControlsEnabled(false);
      return 'error';
    }
  }

  function frameDelayMs() {
    const fps = Number($('phone-fps').value) || 3;
    return Math.round(1000 / fps);
  }

  function showScreen(objectUrl) {
    if (currentObjectUrl) URL.revokeObjectURL(currentObjectUrl);
    currentObjectUrl = objectUrl;
    screen.src = objectUrl;
    screen.classList.remove('hidden');
    placeholder.classList.add('hidden');
  }

  async function previewLoop(myToken) {
    let consecutiveFailures = 0;
    while (previewRunning && myToken === previewToken) {
      if (document.hidden || !$('panel-phone').classList.contains('active')) {
        await sleep(500);
        continue;
      }
      const started = Date.now();
      try {
        const response = await PwBridge.api(`/api/android/screen?t=${started}`);
        if (!response.ok) throw new Error(`frame request failed (${response.status})`);
        const blob = await response.blob();
        if (!previewRunning || myToken !== previewToken) break;
        showScreen(URL.createObjectURL(blob));
        consecutiveFailures = 0;
      } catch (e) {
        consecutiveFailures += 1;
        if (consecutiveFailures >= 3) {
          setMessage(`Preview stopped: ${e.message}. Try "Open in scrcpy" instead.`, 'error');
          stopPreview();
          break;
        }
      }
      const elapsed = Date.now() - started;
      await sleep(Math.max(60, frameDelayMs() - elapsed));
    }
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  function startPreview() {
    if (previewRunning) return;
    previewRunning = true;
    previewToken += 1;
    $('phone-preview-toggle').textContent = 'Stop preview';
    setMessage('Live preview running. Click the screen to tap, drag to swipe.', 'good');
    previewLoop(previewToken);
  }

  function stopPreview() {
    if (!previewRunning) return;
    previewRunning = false;
    previewToken += 1;
    $('phone-preview-toggle').textContent = 'Start preview';
  }

  function toDeviceCoordinates(event) {
    const rect = screen.getBoundingClientRect();
    const naturalWidth = screen.naturalWidth || deviceSize.width;
    const naturalHeight = screen.naturalHeight || deviceSize.height;
    if (!naturalWidth || !naturalHeight || !rect.width || !rect.height) return null;

    // The image is letterboxed by object-fit: contain, so map through the
    // rendered box rather than the element box.
    const scale = Math.min(rect.width / naturalWidth, rect.height / naturalHeight);
    const renderedWidth = naturalWidth * scale;
    const renderedHeight = naturalHeight * scale;
    const offsetX = event.clientX - rect.left - (rect.width - renderedWidth) / 2;
    const offsetY = event.clientY - rect.top - (rect.height - renderedHeight) / 2;
    if (offsetX < 0 || offsetY < 0 || offsetX > renderedWidth || offsetY > renderedHeight) return null;

    return {
      x: Math.round(offsetX / scale),
      y: Math.round(offsetY / scale)
    };
  }

  async function sendInput(payload) {
    try {
      await PwBridge.apiJson('/api/android/input', { method: 'POST', body: payload });
    } catch (e) {
      setMessage(e.message, 'error');
    }
  }

  screen.addEventListener('pointerdown', (event) => {
    if (deviceStatus !== 'ready') return;
    pointerStart = Object.assign({ time: Date.now() }, toDeviceCoordinates(event) || {});
  });

  screen.addEventListener('pointerup', async (event) => {
    if (deviceStatus !== 'ready' || !pointerStart || pointerStart.x === undefined) {
      pointerStart = null;
      return;
    }
    const end = toDeviceCoordinates(event);
    const start = pointerStart;
    pointerStart = null;
    if (!end) return;

    const distance = Math.hypot(end.x - start.x, end.y - start.y);
    if (distance < 16) {
      await sendInput({ action: 'tap', x: end.x, y: end.y });
    } else {
      const duration = Math.min(1200, Math.max(80, Date.now() - start.time));
      await sendInput({ action: 'swipe', x: start.x, y: start.y, x2: end.x, y2: end.y, durationMs: duration });
    }
  });

  document.querySelectorAll('.key').forEach((button) => {
    button.addEventListener('click', () => sendInput({ action: 'key', keycode: button.dataset.keycode }));
  });

  $('phone-text-send').addEventListener('click', async () => {
    const input = $('phone-text');
    if (!input.value) return;
    await sendInput({ action: 'text', text: input.value });
    input.value = '';
  });

  $('phone-text').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      $('phone-text-send').click();
    }
  });

  $('phone-fps').addEventListener('input', () => {
    $('phone-fps-label').textContent = $('phone-fps').value;
  });

  $('phone-refresh').addEventListener('click', refreshDevices);

  $('phone-preview-toggle').addEventListener('click', async () => {
    if (previewRunning) {
      stopPreview();
      return;
    }
    if (deviceStatus !== 'ready' && (await refreshDevices()) !== 'ready') return;
    startPreview();
  });

  picker.addEventListener('change', async () => {
    try {
      await PwBridge.apiJson('/api/android/select', { method: 'POST', body: { serial: picker.value } });
      await refreshDevices();
    } catch (e) {
      setMessage(e.message, 'error');
    }
  });

  $('phone-scrcpy').addEventListener('click', async () => {
    setMessage('Starting scrcpy...', null);
    try {
      await PwBridge.apiJson('/api/android/mirror', { method: 'POST', body: { maxSize: 1024 } });
      setMessage('scrcpy is running in its own window. It gives a much smoother picture than the browser preview.', 'good');
      $('phone-scrcpy-stop').classList.remove('hidden');
      stopPreview();
    } catch (e) {
      setMessage(`${e.message} You can still use the browser preview.`, 'error');
    }
  });

  $('phone-scrcpy-stop').addEventListener('click', async () => {
    try {
      await PwBridge.apiJson('/api/android/mirror/stop', { method: 'POST' });
      setMessage('scrcpy closed.', null);
      $('phone-scrcpy-stop').classList.add('hidden');
    } catch (e) {
      setMessage(e.message, 'error');
    }
  });

  $('wsscrcpy-embed').addEventListener('click', async () => {
    try {
      const body = await PwBridge.apiJson('/api/android/wsscrcpy');
      if (!body.Available) {
        setMessage('ws-scrcpy is no longer reachable on port 8000.', 'error');
        return;
      }
      stopPreview();
      frame.src = body.Url;
      frame.classList.remove('hidden');
      screen.classList.add('hidden');
      placeholder.classList.add('hidden');
      $('wsscrcpy-close').classList.remove('hidden');
    } catch (e) {
      setMessage(e.message, 'error');
    }
  });

  $('wsscrcpy-close').addEventListener('click', () => {
    frame.src = 'about:blank';
    frame.classList.add('hidden');
    $('wsscrcpy-close').classList.add('hidden');
    placeholder.classList.remove('hidden');
  });

  async function detectWsScrcpy() {
    try {
      const body = await PwBridge.apiJson('/api/android/wsscrcpy');
      $('wsscrcpy-block').classList.toggle('hidden', !body.Available);
    } catch (e) {
      $('wsscrcpy-block').classList.add('hidden');
    }
  }

  document.addEventListener('pwbridge-tab-changed', (event) => {
    if (event.detail.panel === 'panel-phone') {
      refreshDevices();
      detectWsScrcpy();
    }
  });

  document.addEventListener('pwbridge-health', (event) => {
    const health = event.detail;
    $('phone-scrcpy').title = health.scrcpy
      ? 'Launch the native scrcpy window'
      : 'scrcpy is not installed. Run "Repair pwbridge-tab" from the Start Menu.';
    $('phone-scrcpy-stop').classList.toggle('hidden', !health.mirroring);
  });

  setControlsEnabled(false);
  setMessage('Connect your phone by USB and press "Check phone".', null);
})();
