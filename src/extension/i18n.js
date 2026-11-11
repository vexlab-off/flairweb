// Flair Web: chrome.i18n.getMessage for Qt WebEngine, which doesn't hand
// extensions their message catalogs. The catalog (the system's language
// over the extension's default one) is written just above at install time.
(() => {
'use strict';
const g = globalThis;
const chrome = g.chrome;
const messages = g.__flairMessages;
if (!chrome || !chrome.i18n || !messages || g.__flairI18n) return;
g.__flairI18n = true;
let native = '';
try { native = chrome.i18n.getMessage('@@extension_id'); } catch (e) {}
if (native) return; // Qt got it right after all.
const locale = (g.__flairLocale || 'en').replace('-', '_');
const special = {
    '@@extension_id': () => chrome.runtime.id,
    '@@ui_locale': () => locale,
    '@@bidi_dir': () => 'ltr', '@@bidi_reversed_dir': () => 'rtl',
    '@@bidi_start_edge': () => 'left', '@@bidi_end_edge': () => 'right',
};
function getMessage(name, substitutions) {
    if (typeof name !== 'string') return '';
    const key = name.toLowerCase();
    if (special[key]) return special[key]();
    const entry = messages[key];
    if (!entry || typeof entry.message !== 'string') return '';
    const subs = substitutions === undefined || substitutions === null ? []
               : (Array.isArray(substitutions) ? substitutions : [substitutions]).map(String);
    const numbered = (text) => text.replace(/\$(\$|\d)/g, (m, d) => d === '$' ? '$$' : (subs[Number(d) - 1] ?? ''));
    const holders = {};
    for (const [k, v] of Object.entries(entry.placeholders || {})) holders[k.toLowerCase()] = v && v.content !== undefined ? String(v.content) : '';
    let text = entry.message.replace(/\$([a-zA-Z0-9_@]+)\$/g, (m, n) => {
        const h = holders[n.toLowerCase()];
        return h === undefined ? m : numbered(h);
    });
    text = numbered(text);
    return text.replace(/\$\$/g, '$');
}
const getUILanguage = () => locale.replace('_', '-');
for (const [k, f] of [['getMessage', getMessage], ['getUILanguage', getUILanguage]]) {
    try { chrome.i18n[k] = f; } catch (e) {}
    if (chrome.i18n[k] !== f) try { Object.defineProperty(chrome.i18n, k, { value: f, configurable: true, writable: true }); } catch (e) {}
}
})();
