import AppKit
import Network

/// A page on localhost with sliders for Stealth mode's look. Moving one changes the panel at once (it stays open over
/// the browser while the page is up); Save keeps the values as Stealth mode's. Only this Mac can reach it (it listens
/// on 127.0.0.1), and every request must carry the random token in the page's address, so no website can change it.
final class StealthTuner {
    static let shared = StealthTuner()
    static let port: UInt16 = 47_719

    private var listener: NWListener?
    private var token = ""
    private weak var panel: SearchPanelController?

    var isRunning: Bool { listener != nil }

    /// Starts the page (or reuses it), opens it in the browser and shows the panel in the look being tuned.
    func open(panel: SearchPanelController) {
        self.panel = panel
        let appearance = PanelAppearance.shared
        appearance.tuning = true
        appearance.preview = appearance.stealthLook
        panel.show()
        // Something in the list to judge the look by.
        if panel.query.trimmingCharacters(in: .whitespaces).isEmpty { panel.query = "stealth" }
        if listener == nil {
            token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    MainActor.assumeIsolated { self?.serve(connection) }
                }
                listener.start(queue: .main)
                self.listener = listener
                log("stealth: tuning page on 127.0.0.1:\(Self.port)")
            } catch {
                log("stealth: couldn't start the tuning page: \(error)")
                panel.flashNote("Couldn't start the tuning page: \(error.localizedDescription)")
                stop(save: false)
                return
            }
        }
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(Self.port)/?t=\(token)")!)
    }

    /// Closes the page's server; the tried look is kept as Stealth's when `save`.
    func stop(save: Bool) {
        let appearance = PanelAppearance.shared
        if save, let look = appearance.preview {
            appearance.stealthLook = look
            appearance.stealth = true
        }
        appearance.preview = nil
        appearance.tuning = false
        listener?.cancel()
        listener = nil
        log("stealth: tuning page closed\(save ? ", look saved" : "")")
    }

    // MARK: HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                    connection.cancel()
                    return
                }
                let (status, type, body) = self.respond(to: request)
                let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                    + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func respond(to request: String) -> (String, String, Data) {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            return ("400 Bad Request", "text/plain", Data("Bad request".utf8))
        }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })
        guard query["t"] == token else { return ("403 Forbidden", "text/plain", Data("Forbidden".utf8)) }
        switch components.path {
        case "/":
            return ("200 OK", "text/html; charset=utf-8", Data(page().utf8))
        case "/set":
            // Only the look changes: showing the panel again would take the keyboard from the slider.
            PanelAppearance.shared.preview = look(from: query)
            return ("204 No Content", "text/plain", Data())
        case "/save":
            PanelAppearance.shared.preview = look(from: query)
            stop(save: true)
            panel?.flashNote("Stealth mode saved and on")
            return ("200 OK", "text/plain", Data("Saved".utf8))
        case "/cancel":
            stop(save: false)
            return ("200 OK", "text/plain", Data("Closed".utf8))
        default:
            return ("404 Not Found", "text/plain", Data("Not found".utf8))
        }
    }

    private func look(from query: [String: String]) -> PanelAppearance.Look {
        let current = PanelAppearance.shared.preview ?? PanelAppearance.shared.stealthLook
        let opacity = query["opacity"].flatMap(Double.init).map { min(1, max(0.15, $0)) } ?? current.opacity
        let tint = query["tint"].flatMap(Double.init).map { min(1, max(0, $0)) } ?? current.tint
        let blur = query["blur"].map { $0 == "1" } ?? current.blur
        return PanelAppearance.Look(opacity: opacity, tint: tint, blur: blur)
    }

    /// The tuning page: three controls, live, with the numbers shown.
    private func page() -> String {
        let look = PanelAppearance.shared.preview ?? PanelAppearance.shared.stealthLook
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>DigUp · Stealth mode</title>
        <style>
        :root{color-scheme:dark;--bg:#0B1530;--card:#142A5C;--fg:#E6EEFF;--muted:#8FAEEF;--accent:#4773E3}
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);
             font:15px -apple-system,BlinkMacSystemFont,sans-serif}
        main{width:min(460px,calc(100vw - 32px));background:var(--card);border-radius:16px;padding:24px 26px}
        h1{font-size:19px;margin:0 0 4px}p{color:var(--muted);margin:0 0 20px;line-height:1.4}
        label{display:block;margin:18px 0 6px;font-weight:600}
        .row{display:flex;gap:12px;align-items:center}
        input[type=range]{flex:1;accent-color:var(--accent)}
        output{width:48px;text-align:right;font-variant-numeric:tabular-nums;color:var(--muted)}
        .check{display:flex;gap:8px;align-items:center;margin-top:18px;font-weight:600}
        .buttons{display:flex;gap:10px;justify-content:flex-end;margin-top:26px}
        button{font:inherit;border:0;border-radius:9px;padding:9px 16px;cursor:pointer;background:#0B1530;color:var(--fg)}
        button.primary{background:var(--accent);color:#fff;font-weight:600}
        #done{display:none;color:var(--muted);margin-top:16px}
        </style></head><body><main>
        <h1>Stealth mode</h1>
        <p>DigUp's panel is open over this page: move the sliders and watch it change. Save keeps these values for
        Stealth mode and turns it on.</p>
        <label for="opacity">Whole panel, text included</label>
        <div class="row"><input id="opacity" type="range" min="15" max="100" value="\(Int(look.opacity * 100))"><output id="opacityOut"></output></div>
        <label for="tint">Background tint</label>
        <div class="row"><input id="tint" type="range" min="0" max="100" value="\(Int(look.tint * 100))"><output id="tintOut"></output></div>
        <div class="check"><input id="blur" type="checkbox" \(look.blur ? "checked" : "")><label for="blur" style="margin:0">Blur what's behind</label></div>
        <div class="buttons"><button id="cancel">Cancel</button><button id="save" class="primary">Save as Stealth</button></div>
        <div id="done"></div>
        </main><script>
        const t = new URLSearchParams(location.search).get('t');
        const $ = id => document.getElementById(id);
        const values = () => `opacity=${$('opacity').value / 100}&tint=${$('tint').value / 100}&blur=${$('blur').checked ? 1 : 0}`;
        const show = () => { $('opacityOut').textContent = $('opacity').value + '%'; $('tintOut').textContent = $('tint').value + '%'; };
        let pending = false, again = false;
        const send = () => {
          show();
          if (pending) { again = true; return; }
          pending = true;
          fetch(`/set?t=${t}&${values()}`).finally(() => { pending = false; if (again) { again = false; send(); } });
        };
        ['opacity', 'tint'].forEach(id => $(id).addEventListener('input', send));
        $('blur').addEventListener('change', send);
        const finish = (path, text) => fetch(`/${path}?t=${t}&${values()}`).then(() => {
          document.querySelectorAll('input,button').forEach(e => e.disabled = true);
          $('done').style.display = 'block'; $('done').textContent = text;
        });
        $('save').onclick = () => finish('save', 'Saved: Stealth mode is on. You can close this tab.');
        $('cancel').onclick = () => finish('cancel', 'Nothing changed. You can close this tab.');
        show();
        </script></body></html>
        """
    }
}
