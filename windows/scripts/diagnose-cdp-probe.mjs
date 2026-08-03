// Diagnostic helper: connect to a CDP page target, dump shell markers and a
// screenshot. Used by diagnose-cdp-launch.ps1; not part of the skin runtime.
import { writeFileSync } from "node:fs";

const wsUrl = process.argv[2];
const screenshotPath = process.argv[3] || null;
if (!wsUrl) {
  console.error("usage: node diagnose-cdp-probe.mjs <wsUrl> [screenshotPath]");
  process.exit(2);
}

const ws = new WebSocket(wsUrl);
let nextId = 1;
const pending = new Map();

function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

ws.addEventListener("message", (event) => {
  let message;
  try {
    message = JSON.parse(String(event.data));
  } catch {
    return;
  }
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  }
});

const hardTimeout = setTimeout(() => {
  console.error("WS open timeout");
  process.exit(1);
}, 8000);

function sendWithTimeout(method, params = {}, timeoutMs = 10000) {
  const request = send(method, params);
  return Promise.race([
    request,
    new Promise((_, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out after ${timeoutMs}ms`)), timeoutMs);
      timer.unref?.();
    }),
  ]);
}

ws.addEventListener("open", async () => {
  clearTimeout(hardTimeout);
  try {
    const probe = await sendWithTimeout("Runtime.evaluate", {
      expression: `(() => {
        const queryAny = (selectors) => selectors.some((s) => {
          try { return Boolean(document.querySelector(s)); } catch { return false; }
        });
        return {
          url: location.href,
          title: document.title,
          readyState: document.readyState,
          bodyLength: document.body ? document.body.innerHTML.length : -1,
          bodyText: (document.body ? document.body.innerText : "").slice(0, 300),
          markers: {
            shell: queryAny(['main.main-surface', 'main', '[role="main"]']),
            sidebar: queryAny(['aside.app-shell-left-panel', 'aside', 'nav[aria-label]', '[data-testid*="sidebar"]']),
            composer: queryAny([
              '.composer-surface-chrome',
              '[data-testid*="composer"]',
              'form textarea',
              'textarea[placeholder]',
              '[contenteditable="true"][role="textbox"]',
              'div[contenteditable="true"]',
            ]),
            main: Boolean(document.querySelector('[role="main"]')),
          },
          homeIcon: Boolean(document.querySelector('[data-testid="home-icon"]')),
          homeBanners: Boolean(document.querySelector('.home-banners')),
          skinApplied: Boolean(document.documentElement.classList.contains('codex-dream-skin')),
        };
      })()`,
      returnByValue: true,
    });
    let screenshot = null;
    if (screenshotPath) {
      try {
        const shot = await sendWithTimeout("Page.captureScreenshot", {
          format: "png",
          fromSurface: true,
          captureBeyondViewport: false,
        }, 15000);
        writeFileSync(screenshotPath, Buffer.from(shot.data, "base64"));
        screenshot = screenshotPath;
      } catch (error) {
        screenshot = "error: " + error.message;
      }
    }
    console.log(JSON.stringify({ probe: probe.result.value, screenshot }, null, 2));
    ws.close();
    process.exit(0);
  } catch (error) {
    console.error(String(error?.stack || error));
    try { ws.close(); } catch {}
    process.exit(1);
  }
});

ws.addEventListener("error", () => {
  clearTimeout(hardTimeout);
  console.error("CDP WebSocket connection failed");
  process.exit(1);
});
