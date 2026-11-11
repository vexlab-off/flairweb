Extension de test de la couche de compatibilité (`src/extension/`, `ExtensionHost`, `Extensions.qml`).

    FLAIRWEB_EXTLOG=1 FLAIRWEB_DEV="installdir:$PWD/tests/extension-selftest" build/flairweb
    FLAIRWEB_EXTLOG=1 build/flairweb https://example.com/

Sur example.com, le journal doit montrer `SELFTEST` pour webNavigation, executeScript (isolé et MAIN),
sendMessage, insertCSS, getAllFrames, storage.session et i18n, et le badge « OK » apparaît.
