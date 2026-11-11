// Flair Web on the Chrome Web Store (isolated world, every store page).
// The store greys out its button and shows "Switch to Chrome" for any
// browser that is not Google Chrome. Here, the banner goes, and the button
// becomes "Ajouter à Flair Web": a click asks Flair Web (through a console
// message it listens for) to install the extension or theme of the page.
// Flair Web writes the ids it has installed on <html data-flairweb-installed>.
(() => {
    if (location.hostname !== "chromewebstore.google.com") return;
    const MARK = "__flairweb_store__:";
    const banner = /(Passez à Chrome|Switch to Chrome|Wechseln Sie zu Chrome|Cambia a Chrome|Passa a Chrome|Élément actuellement indisponible|Item currently unavailable|Cet élément n'est pas disponible|This item is not available)/i;
    const storeButton = /^(Ajouter à (Google )?Chrome|Add to (Google )?Chrome|Supprimer de (Google )?Chrome|Remove from (Google )?Chrome|Zu Chrome hinzufügen|Añadir a Chrome|Aggiungi a Chrome|Disponible sur Chrome|Available on Chrome)$/i;

    const currentId = () => {
        const m = /\/detail\/(?:[^/]+\/)?([a-p]{32})(?:[/?#]|$)/.exec(location.pathname);
        return m ? m[1] : "";
    };
    const installed = () => (document.documentElement.getAttribute("data-flairweb-installed") || "").split(",");
    const installing = () => document.documentElement.getAttribute("data-flairweb-installing") === "1";

    // The smallest block around the banner's text: hidden.
    function hideBanner() {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!banner.test((node.nodeValue || "").replace(/\s+/g, " "))) continue;
            let box = node.parentElement;
            // Up to the block that holds the banner and its link, no further.
            const own = (node.nodeValue || "").trim().length;
            while (box && box.parentElement && box.parentElement !== document.body &&
                   (box.parentElement.innerText || "").trim().length < own + 40) box = box.parentElement;
            if (box && box !== document.body && !box.hasAttribute("data-flairweb-hidden")) {
                box.setAttribute("data-flairweb-hidden", "");
                box.style.setProperty("display", "none", "important");
            }
        }
    }

    function label(id) {
        if (installed().indexOf(id) >= 0) return "Installée dans Flair Web";
        if (installing()) return "Installation…";
        return "Ajouter à Flair Web";
    }

    function ours(original) {
        let button = original.parentElement && original.parentElement.querySelector(":scope > [data-flairweb-add]");
        if (button) return button;
        button = document.createElement("button");
        button.type = "button";
        button.setAttribute("data-flairweb-add", "");
        button.style.cssText = [
            "font: 500 14px/20px 'Google Sans', Roboto, Arial, sans-serif", "letter-spacing: .25px",
            "padding: 10px 24px", "border-radius: 20px", "border: 0", "cursor: pointer",
            "background: #0b57d0", "color: #fff", "min-height: 40px", "white-space: nowrap"
        ].join(";");
        button.addEventListener("click", (event) => {
            event.preventDefault();
            event.stopPropagation();
            const id = currentId();
            if (!id || installed().indexOf(id) >= 0 || installing()) return;
            document.documentElement.setAttribute("data-flairweb-installing", "1");
            update();
            console.log(MARK + "install:" + id);
        }, true);
        original.insertAdjacentElement("afterend", button);
        return button;
    }

    function update() {
        hideBanner();
        const id = currentId();
        for (const original of document.querySelectorAll("button")) {
            if (original.hasAttribute("data-flairweb-add")) continue;
            // The store's labels use non-breaking spaces.
            if (!storeButton.test((original.innerText || "").replace(/\s+/g, " ").trim())) continue;
            original.style.setProperty("display", "none", "important");
            if (!id) continue;
            const button = ours(original);
            const text = label(id);
            if (button.textContent !== text) button.textContent = text;
            const done = installed().indexOf(id) >= 0;
            button.disabled = done || installing();
            button.style.background = done ? "#e7f2e9" : "#0b57d0";
            button.style.color = done ? "#146c2e" : "#fff";
            button.style.opacity = installing() ? "0.7" : "1";
        }
    }

    let queued = false;
    const schedule = () => {
        if (queued) return;
        queued = true;
        setTimeout(() => { queued = false; update(); }, 60);
    };
    const start = () => {
        update();
        new MutationObserver(schedule).observe(document.documentElement,
            { childList: true, subtree: true, attributes: true, attributeFilter: ["data-flairweb-installed", "data-flairweb-installing"] });
    };
    if (document.body) start(); else document.addEventListener("DOMContentLoaded", start, { once: true });
})();
