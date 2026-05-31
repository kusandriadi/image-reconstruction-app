const $ = (sel) => document.querySelector(sel);

const fileInput = $('#fileInput');
const okBtn = $('#okBtn');
const cancelBtn = $('#cancelBtn');
const resetBtn = $('#resetBtn');
const modelSelect = $('#modelSelect');
const bar = $('#bar');
const progress = $('#progress');
const statusEl = $('#status');
const preview = $('#preview');
const downloadLink = $('#downloadLink');
const dropZone = $('#dropZone');
const filePreview = $('#filePreview');
const progressPercent = $('#progressPercent');
const progressText = $('#progressText');
const outputPlaceholder = $('#outputPlaceholder');
const warningBanner = $('#warningBanner');
const warningMessage = $('#warningMessage');
const comparison = $('#comparison');
const beforeImg = $('#beforeImg');
const compareHandle = $('#compareHandle');
const installBtn = $('#installBtn');

let currentJobId = null;
let pollTimer = null;
let inputObjectURL = null;

// Configuration from centralized config via backend API
// No hardcoded defaults - will be loaded from backend
let appConfig = null;

// Get BACKEND URL from localStorage or fetch from config
let BACKEND = window.BACKEND_BASE;

// Load configuration from backend on startup
async function loadConfig() {
  try {
    // If no BACKEND set, use current origin (works in production) or localhost (dev)
    if (!BACKEND) {
      // In production (with Nginx), use current origin
      // In development, use localhost:8000
      const isProduction = window.location.protocol === 'https:' || window.location.hostname !== 'localhost';
      BACKEND = isProduction ? window.location.origin : 'http://localhost:8000';
    }

    const res = await fetch(`${BACKEND}/api/config`);
    if (res.ok) {
      appConfig = await res.json();

      // Update BACKEND URL from config if not set by localStorage
      if (!window.BACKEND_BASE) {
        BACKEND = appConfig.backend_url;
      }

      console.log('Configuration loaded from backend:', appConfig);

      // Apply UI configuration
      applyUIConfig();
    } else {
      console.error('Failed to load config from backend');
      throw new Error('Config load failed');
    }
  } catch (e) {
    console.error('Could not fetch config from backend:', e.message);
    alert('Failed to load application configuration. Please ensure the backend is running.');
    throw e;
  }
}

// Apply UI configuration from loaded config
function applyUIConfig() {
  if (!appConfig) return;

  // Update page title
  if (appConfig.ui?.title) {
    document.title = appConfig.ui.title;
    const h1 = document.querySelector('h1');
    if (h1) h1.textContent = appConfig.ui.title;
  }

  // Update labels (preserve SVG icons inside buttons)
  if (appConfig.ui?.labels) {
    const inputLabel = document.querySelector('label[class="label"]:first-of-type');
    if (inputLabel) inputLabel.textContent = appConfig.ui.labels.input;

    const outputLabel = document.querySelector('label[class="label"]:last-of-type');
    if (outputLabel) outputLabel.textContent = appConfig.ui.labels.output;

    // Update button text without removing SVG icons
    const setBtnText = (btn, text) => {
      if (!btn) return;
      const textNodes = [...btn.childNodes].filter(n => n.nodeType === Node.TEXT_NODE);
      if (textNodes.length) {
        textNodes.forEach(n => n.textContent = '');
        textNodes[textNodes.length - 1].textContent = ' ' + text;
      } else {
        btn.append(' ' + text);
      }
    };
    setBtnText(okBtn, appConfig.ui.labels.ok_button);
    setBtnText(cancelBtn, appConfig.ui.labels.cancel_button);
    setBtnText(downloadLink, appConfig.ui.labels.download_button);
  }

  // Update file input accept attribute
  if (appConfig.file_input?.accept && fileInput) {
    fileInput.setAttribute('accept', appConfig.file_input.accept);
  }

  // Update preview alt text
  if (appConfig.ui?.preview_alt_text && preview) {
    preview.alt = appConfig.ui.preview_alt_text;
  }

  // Build model options from config (single source of truth)
  if (modelSelect && Array.isArray(appConfig.ui?.models)) {
    modelSelect.innerHTML = '';
    appConfig.ui.models.forEach((m) => {
      const opt = document.createElement('option');
      opt.value = m.value;
      opt.textContent = m.label;
      modelSelect.appendChild(opt);
    });
  }

  // Show/hide model selector based on config
  const modelSelectorElement = document.querySelector('.model-selector');
  if (modelSelectorElement) {
    if (appConfig.ui?.enable_model_selection === false) {
      modelSelectorElement.style.display = 'none';
    } else {
      modelSelectorElement.style.display = 'flex';
    }
  }
}

// Helper function to format message templates
function formatMessage(template, params) {
  if (!template) return '';
  let message = template;
  for (const [key, value] of Object.entries(params)) {
    message = message.replace(`{${key}}`, value);
  }
  return message;
}

function resetUI() {
  currentJobId = null;
  if (pollTimer) clearInterval(pollTimer);
  okBtn.disabled = !fileInput.files.length;
  cancelBtn.disabled = true;
  resetBtn.classList.add('hidden');
  bar.style.width = '0%';
  if (progressPercent) progressPercent.textContent = '0%';
  progress.classList.add('hidden');
  statusEl.textContent = '';
  comparison.classList.add('hidden');
  preview.removeAttribute('src');
  beforeImg.removeAttribute('src');
  downloadLink.classList.add('hidden');
  downloadLink.href = '#';
  if (outputPlaceholder) outputPlaceholder.classList.remove('hidden');
}

function resetAll() {
  // Reset file input
  fileInput.value = '';
  if (filePreview) filePreview.classList.add('hidden');
  if (inputObjectURL) { URL.revokeObjectURL(inputObjectURL); inputObjectURL = null; }
  resetUI();
}

// ── Before/after comparison slider ──────────────────────────────────────────
let comparisonReady = false;

function setComparePos(clientX) {
  const rect = comparison.getBoundingClientRect();
  let pct = ((clientX - rect.left) / rect.width) * 100;
  pct = Math.max(0, Math.min(100, pct));
  comparison.style.setProperty('--pos', pct + '%');
}

function initComparison() {
  comparison.style.setProperty('--pos', '50%');
  if (comparisonReady) return; // attach listeners once
  comparisonReady = true;

  let dragging = false;
  comparison.addEventListener('pointerdown', (e) => {
    if (comparison.classList.contains('no-before')) return;
    dragging = true;
    try { comparison.setPointerCapture(e.pointerId); } catch (_) {}
    setComparePos(e.clientX);
  });
  comparison.addEventListener('pointermove', (e) => {
    if (dragging) setComparePos(e.clientX);
  });
  const stop = () => { dragging = false; };
  comparison.addEventListener('pointerup', stop);
  comparison.addEventListener('pointercancel', stop);

  compareHandle.addEventListener('keydown', (e) => {
    const cur = parseFloat(getComputedStyle(comparison).getPropertyValue('--pos')) || 50;
    if (e.key === 'ArrowLeft') { comparison.style.setProperty('--pos', Math.max(0, cur - 4) + '%'); e.preventDefault(); }
    if (e.key === 'ArrowRight') { comparison.style.setProperty('--pos', Math.min(100, cur + 4) + '%'); e.preventDefault(); }
  });
}

// ── PWA: service worker + install prompt ────────────────────────────────────
function registerServiceWorker() {
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js').catch((e) => console.warn('SW registration failed:', e));
    });
  }
}

let deferredPrompt = null;
function setupInstallPrompt() {
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    deferredPrompt = e;
    if (installBtn) installBtn.classList.remove('hidden');
  });
  if (installBtn) {
    installBtn.addEventListener('click', async () => {
      if (!deferredPrompt) return;
      deferredPrompt.prompt();
      await deferredPrompt.userChoice;
      deferredPrompt = null;
      installBtn.classList.add('hidden');
    });
  }
  window.addEventListener('appinstalled', () => {
    if (installBtn) installBtn.classList.add('hidden');
    deferredPrompt = null;
  });
}

function showFilePreview(file) {
  if (filePreview) {
    filePreview.textContent = `📄 ${file.name}`;
    filePreview.classList.remove('hidden');
  }
}

function updateProgress(percent) {
  bar.style.width = percent + '%';
  if (progressPercent) {
    progressPercent.textContent = Math.round(percent) + '%';
  }
}

function handleFileSelect(file) {
  // Validate file on selection
  if (file && appConfig) {
    // Don't enable upload if model is unavailable
    if (warningBanner && !warningBanner.classList.contains('hidden')) {
      showFilePreview(file);
      okBtn.disabled = true;
      return;
    }

    const fileSizeMB = file.size / (1024 * 1024);

    if (fileSizeMB > appConfig.upload.max_size_mb) {
      const msg = formatMessage(appConfig.ui.messages.file_too_large, {
        max_size: appConfig.upload.max_size_mb
      });
      statusEl.textContent = `Error: ${msg}`;
      okBtn.disabled = true;
      return;
    }

    const fileExt = '.' + file.name.split('.').pop().toLowerCase();
    if (!appConfig.upload.allowed_extensions.includes(fileExt)) {
      const msg = formatMessage(appConfig.ui.messages.file_type_not_allowed, {
        allowed_types: appConfig.upload.allowed_extensions.join(', ')
      });
      statusEl.textContent = `Error: ${msg}`;
      okBtn.disabled = true;
      return;
    }

    // Keep an object URL of the original for the before/after comparison
    if (inputObjectURL) URL.revokeObjectURL(inputObjectURL);
    inputObjectURL = URL.createObjectURL(file);

    showFilePreview(file);
    okBtn.disabled = false;
  }
}

fileInput.addEventListener('change', () => {
  resetUI();
  okBtn.disabled = !fileInput.files.length;

  if (fileInput.files.length > 0) {
    handleFileSelect(fileInput.files[0]);
  }
});

// Drag and drop functionality
if (dropZone) {
  ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
    dropZone.addEventListener(eventName, preventDefaults, false);
  });

  function preventDefaults(e) {
    e.preventDefault();
    e.stopPropagation();
  }

  ['dragenter', 'dragover'].forEach(eventName => {
    dropZone.addEventListener(eventName, () => {
      dropZone.classList.add('drag-over');
    }, false);
  });

  ['dragleave', 'drop'].forEach(eventName => {
    dropZone.addEventListener(eventName, () => {
      dropZone.classList.remove('drag-over');
    }, false);
  });

  dropZone.addEventListener('drop', (e) => {
    const dt = e.dataTransfer;
    const files = dt.files;

    if (files.length > 0) {
      fileInput.files = files;
      resetUI();
      handleFileSelect(files[0]);
    }
  }, false);
}

okBtn.addEventListener('click', async () => {
  if (!fileInput.files.length || !appConfig) return;

  // Show progress bar only if enabled in config
  if (appConfig.ui.show_progress_bar) {
    progress.classList.remove('hidden');
  }
  updateProgress(5);
  if (progressText) progressText.textContent = 'Uploading...';
  statusEl.textContent = appConfig.ui.messages.uploading;
  okBtn.disabled = true;
  cancelBtn.disabled = false;

  const form = new FormData();
  form.append('file', fileInput.files[0]);

  // Send the selected model; if the picker is hidden/empty, default to the
  // first configured model.
  if (modelSelect && modelSelect.value) {
    form.append('model', modelSelect.value);
  } else if (appConfig.ui?.models?.length) {
    form.append('model', appConfig.ui.models[0].value);
  }

  try {
    const res = await fetch(`${BACKEND}/api/reconstructions`, {
      method: 'POST',
      body: form
    });
    if (!res.ok) {
      const errData = await res.json().catch(() => null);
      const detail = errData?.detail || appConfig.ui.messages.create_job_failed;
      throw new Error(detail);
    }
    const data = await res.json();
    currentJobId = data.job_id;
    if (progressText) progressText.textContent = 'Processing...';
    startPolling();
  } catch (e) {
    statusEl.textContent = 'Error: ' + e.message;
    progress.classList.add('hidden');
    cancelBtn.disabled = true;
    okBtn.disabled = false;
  }
});

cancelBtn.addEventListener('click', async () => {
  if (!currentJobId || !appConfig) return;
  cancelBtn.disabled = true;
  statusEl.textContent = appConfig.ui.messages.cancelling;
  try {
    await fetch(`${BACKEND}/api/reconstructions/${currentJobId}`, { method: 'DELETE' });
  } catch (e) {
    // ignore
  }
});

resetBtn.addEventListener('click', () => {
  resetAll();
});

function startPolling() {
  if (pollTimer) clearInterval(pollTimer);
  if (!appConfig) return;

  // Use polling interval from config
  const pollingInterval = appConfig.polling.interval_ms;

  pollTimer = setInterval(async () => {
    if (!currentJobId) return;
    try {
      const res = await fetch(`${BACKEND}/api/reconstructions/${currentJobId}`);
      if (!res.ok) {
        if (res.status === 404) {
          throw new Error('Job not found (404)');
        }
        throw new Error('Status check failed');
      }
      const job = await res.json();
      const pct = Math.max(0, Math.min(100, job.progress || 0));
      updateProgress(pct);

      // Don't surface the raw technical status/message (e.g. "running - running
      // model (tile 4/9)") — the progress bar and progress text convey state.
      statusEl.textContent = '';

      if (job.status === 'completed') {
        clearInterval(pollTimer);
        cancelBtn.disabled = true;
        okBtn.disabled = true;
        resetBtn.classList.remove('hidden');
        if (progressText) progressText.textContent = 'Completed!';
        const resultUrl = `${BACKEND}/api/reconstructions/${currentJobId}/result`;

        // Hide output placeholder
        if (outputPlaceholder) outputPlaceholder.classList.add('hidden');

        // Show the before/after comparison
        if (appConfig.ui.preview_enabled) {
          preview.src = resultUrl;
          if (inputObjectURL) {
            beforeImg.src = inputObjectURL;
            comparison.classList.remove('no-before');
          } else {
            comparison.classList.add('no-before');
          }
          comparison.classList.remove('hidden');
          initComparison();
        }

        // Show download link only if enabled in config
        if (appConfig.ui.download_enabled) {
          downloadLink.href = resultUrl;
          downloadLink.download = `${currentJobId}.png`;
          downloadLink.classList.remove('hidden');
        }
      } else if (job.status === 'failed' || job.status === 'cancelled') {
        clearInterval(pollTimer);
        cancelBtn.disabled = true;
        resetBtn.classList.remove('hidden');
        let failedText = job.status === 'failed' ? 'Failed' : 'Cancelled';
        if (progressText) progressText.textContent = failedText;
      }
    } catch (e) {
      // Check if it's a 404 error (job not found - likely backend restarted)
      if (e.message.includes('404')) {
        // Stop polling on 404 to avoid spamming the backend
        clearInterval(pollTimer);
        cancelBtn.disabled = true;
        resetBtn.classList.remove('hidden');
        statusEl.textContent = 'Job not found (server may have restarted)';
        if (progressText) progressText.textContent = 'Error';
      } else {
        // show but keep trying for other errors
        const msg = formatMessage(appConfig.ui.messages.polling_error, { error: e.message });
        statusEl.textContent = msg;
      }
    }
  }, pollingInterval);
}

// Check backend health and warn if model is not available
async function checkHealth() {
  try {
    const res = await fetch(`${BACKEND}/api/health`);
    if (res.ok) {
      const health = await res.json();
      if (!health.model_available) {
        if (warningBanner && warningMessage) {
          warningMessage.textContent = 'Model files not found. Image processing is unavailable. Please download the model files (see README).';
          warningBanner.classList.remove('hidden');
        }
        okBtn.disabled = true;
      }
    }
  } catch (e) {
    console.error('Health check failed:', e.message);
  }
}

// Initialize app
async function init() {
  await loadConfig();
  resetUI();
  await checkHealth();
  console.log('PixUp initialized with config:', appConfig);
}

// Run initialization
registerServiceWorker();
setupInstallPrompt();
init();

