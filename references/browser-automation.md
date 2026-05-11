# Browser automation — when to reach for it, when to walk away

## The bottom line

**Don't.** 95% of the time, the service has a Management API that replaces whatever you were trying to script in the browser. Use the API.

The remaining 5% are:
- Generating an API token for the first time (no API can issue an API token).
- OAuth flows that issue a long-lived token in exchange for a short browser session.
- Email verification clicks.
- Reading a value Render/Vercel displays once on first-create.

For these, you do need a browser. Below is how to do it cleanly.

## Three approaches, ranked

### 1. Tell the user what to click (preferred)

For one-shot UI interactions, copy-paste-able instructions beat any automation:

> Open https://supabase.com/dashboard/account/tokens
> Click **Generate new token**, name it "deploy script"
> Copy the `sbp_...` value back here.

Cost: 30 seconds of user time. Reliability: 100%. No code to maintain.

### 2. JavaScript-in-a-real-browser (when scripting is needed)

If you're driving a multi-step UI flow (Vercel env paste, then deploy click), the cleanest path on macOS is to inject JavaScript into the user's real Chrome via osascript.

**Prerequisite**: user enables **Chrome → View → Developer → Allow JavaScript from Apple Events** once. This is a per-machine setting.

```bash
# Run JS in the front Chrome tab
osascript -e '
  tell application "Google Chrome"
    tell front window
      execute active tab javascript "document.title"
    end tell
  end tell
'
```

For multi-line JS, write to a temp file and read it back:

```bash
cat > /tmp/click_deploy.js <<'JS'
const btn = [...document.querySelectorAll('button')]
  .find(b => b.textContent.trim() === 'Deploy');
if (!btn) throw new Error('no deploy button');
if (btn.disabled) throw new Error('deploy button still disabled');
btn.click();
'ok'
JS

osascript -e '
  on run argv
    set js to (read POSIX file (item 1 of argv))
    tell application "Google Chrome"
      tell front window
        execute active tab javascript js
      end tell
    end tell
  end run
' /tmp/click_deploy.js
```

This works because Chrome's JS engine runs against the real DOM with the user's real cookies. Sites can't distinguish your osascript call from a normal DevTools execution.

**Limits**:
- Doesn't simulate real keyboard / mouse — synthetic events only.
- Some sites detect when `dispatchEvent` is used without `isTrusted: true` (you can't fake `isTrusted` from page-context JS).
- The `ClipboardEvent('paste')` trick mostly bypasses this (paste handlers accept synthetic clipboard events on most React forms).

### 3. Playwright (last resort)

If the UI has anti-bot detection that even real-Chrome-via-osascript can't bypass, drop to Playwright with stealth plugins. This is far more setup, and most services flagged by Playwright also have a Management API. **Almost always not the answer.**

## What you cannot do from JS alone

These need OS-level Accessibility permission, which JS doesn't have:

- **Real keyboard events** (`isTrusted: true` keystrokes).
- **Mouse movement** (some bot checks require non-instant cursor paths).
- **Trusted clicks** during anti-bot disable periods (GitHub OAuth Authorize button has a 2-4 s startup phase where JS clicks are ignored).
- **System dialogs** (file picker, permission prompts).

For these, ask the user. The flow is:

> I've staged the env block on the clipboard. Please:
>   1. Click the **Key** input on the env tab (placeholder: `EXAMPLE_NAME`)
>   2. Press Cmd+V
>   3. Hit Reply when you've done that.

A 30-second user interrupt is cheaper than 30 minutes of Playwright-stealth debugging.

## Patterns that consistently work

### Find a button by text

```js
const btn = [...document.querySelectorAll('button')]
  .find(b => b.textContent.trim() === 'Deploy');
btn?.click();
```

`.click()` works for buttons that don't have anti-bot guards (e.g., Vercel's Deploy button after env is filled).

### Pasting a multi-line env block

See `references/vercel.md` for the canonical ClipboardEvent example.

### Reading a value shown once

```js
// Render shows the database password once; copy it to clipboard
const pw = document.querySelector('[data-test=db-password]')?.textContent;
copy(pw); // DevTools magic global
```

### Finding a form by action URL

When a button is text-wrapped in nested spans (GitHub's OAuth Authorize is the worst offender), the surrounding form is easier to grab:

```js
document.querySelector('form[action="/login/oauth/authorize"]')?.submit();
```

## Network-mode caveats

If the user is behind a TUN-mode proxy (Clash, Mihomo with fakeip):
- DNS lookups from osascript-launched processes inherit the proxy.
- Direct TCP to non-HTTPS ports fails (5432, 6379, 22).
- HTTPS works.

osascript itself runs in user mode and respects system proxy settings. Same for Chrome.

When debugging "the script works in Chrome DevTools but not from osascript", check:
1. JS-from-Apple-Events is enabled in Chrome.
2. You're addressing `front window`, not all windows.
3. Your JS doesn't throw — wrap in try/catch and return the error message.

## Final reminder

Every minute you spend automating a UI is a minute you could spend reading the API docs. The API path is shorter 90% of the time and never breaks when the vendor redesigns their dashboard.
