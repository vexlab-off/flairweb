chrome.runtime.onMessage.addListener((m, sender, reply) => { reply({ pong: m.ping, from: location.host }); });
