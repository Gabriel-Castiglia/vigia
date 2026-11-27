// Vigia: the editor page in a WKWebView, and what it may reach.
// Copyright (C) 2026 Gabriel Castiglia. Licensed under the GNU GPL, version 2 only.
// Date: November 10, 2026
// SPDX-License-Identifier: GPL-2.0-only
//
// The page (web/) is the one of the Windows version. On Windows it is served from
// https://app.local/ and the document's folder from https://doc.local/; here two private schemes
// do the same: gm-app://app/ serves the app's own web folder and gm-doc://doc/<path> the files a
// document may reach (its folder, or the Files panel folders: Wiki.swift), so relative pictures
// and links work. The page's base is the document's own folder under gm-doc://doc/, so ../ links
// resolve as on disk; the handler refuses anything outside the reach. Every other navigation
// is cancelled and handed to the link policy (LinkPolicy.swift). The page talks to the app through
// window.chrome.webview.postMessage, which a small script maps to WebKit's message handler.

import AppKit
import WebKit

enum Schemes {
    static let app = "gm-app"
    static let doc = "gm-doc"
    static let appBase = "gm-app://app/"
    static let docBase = "gm-doc://doc/"

    /// The page base for a document in `dir`: gm-doc://doc/<absolute path of dir>/.
    static func docBase(for dir: URL?) -> String {
        guard let dir else { return docBase }
        var c = URLComponents()
        c.scheme = doc; c.host = "doc"; c.path = dir.standardizedFileURL.path
        let s = c.string ?? docBase
        return s.hasSuffix("/") ? s : s + "/"
    }

    /// The page's address of a file: gm-doc://doc/<absolute path>.
    static func address(of file: URL) -> String {
        var c = URLComponents()
        c.scheme = doc; c.host = "doc"; c.path = file.standardizedFileURL.path
        return c.string ?? docBase
    }

    /// The file a gm-doc address stands for (no check of reach here).
    static func file(of url: URL) -> URL? {
        guard url.scheme == doc else { return nil }
        let p = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding ?? url.path
        return p.hasPrefix("/") ? URL(fileURLWithPath: p).standardizedFileURL : nil
    }
}

/// Serves gm-doc://doc/<absolute path> for files inside `reach`, and pictures from anywhere (an absolute path or
/// file: address of a picture in a document, as Windows does since 2.0.0); nothing else outside `reach`.
final class DocSchemeHandler: NSObject, WKURLSchemeHandler {
    var reach: [URL] = []

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Schemes.file(of: url),
              Wiki.inside(file, any: reach) || LinkPolicy.pictures.contains(file.pathExtension.lowercased()),
              let data = try? Data(contentsOf: file.resolvingSymlinksInPath()) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let type = FolderSchemeHandler.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// Serves files under `root` for one scheme, never outside it.
final class FolderSchemeHandler: NSObject, WKURLSchemeHandler {
    var root: URL?
    /// The page's own files (index.html, app.js) are rewritten so their https://app.local/
    /// addresses point to gm-app://app/; the libraries are served untouched.
    let rewriteIndex: Bool

    init(root: URL?, rewriteIndex: Bool) {
        self.root = root
        self.rewriteIndex = rewriteIndex
    }

    static let types: [String: String] = [
        "html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp",
        "bmp": "image/bmp", "json": "application/json", "txt": "text/plain", "md": "text/plain",
    ]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = root?.standardizedFileURL else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let rel = (url.path.removingPercentEncoding ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let file = root.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.resolvingSymlinksInPath().path
        guard file.path == base || file.path.hasPrefix(base + "/"),
              var data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let ext = file.pathExtension.lowercased()
        if rewriteIndex && (ext == "html" || ext == "js" && !rel.hasPrefix("lib/")), let s = String(data: data, encoding: .utf8) {
            // Also the Content-Security-Policy of index.html, which names the hosts without the final slash.
            data = Data(s.replacingOccurrences(of: "https://app.local/", with: Schemes.appBase)
                         .replacingOccurrences(of: "https://app.local", with: Schemes.app + "://app")
                         .replacingOccurrences(of: "https://doc.local", with: Schemes.doc + "://doc").utf8)
        }
        let type = FolderSchemeHandler.types[ext] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// One editor page. Messages from the page go to `onMessage`; links to `onLink`.
final class EditorWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    let docHandler = DocSchemeHandler()
    var onMessage: (([String: Any]) -> Void)?
    var onLink: ((String) -> Void)?
    var onFileDrop: ((URL) -> Void)?

    static var webFolder: URL? { Bundle.main.url(forResource: "web", withExtension: nil) }

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(FolderSchemeHandler(root: EditorWeb.webFolder, rewriteIndex: true), forURLScheme: Schemes.app)
        config.setURLSchemeHandler(docHandler, forURLScheme: Schemes.doc)
        let shim = """
            window.chrome = { webview: { postMessage: function (m) { window.webkit.messageHandlers.host.postMessage(m); } } };
            """
        config.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Live reload happens while the user works in another app (often the AI assistant that
        // edits the file): the page must keep its timers running when the window is behind.
        config.preferences.inactiveSchedulingPolicy = .none
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(WeakHandler(self), name: "host")
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsMagnification = false
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: URL(string: Schemes.appBase + "index.html")!))
    }

    /// The folders the document's pictures may come from (Wiki.reach).
    func setReach(_ folders: [URL]) { docHandler.reach = folders }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let d = message.body as? [String: Any] { onMessage?(d) }
    }

    /// Runs `mdApp.<call>` with JSON-safe arguments and returns its result.
    @discardableResult
    func call(_ body: String, _ args: [String: Any] = [:]) async -> Any? {
        try? await view.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: .page)
    }

    // Only the app's own page loads in the view. A drop of a file arrives as a navigation to it.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == Schemes.app && action.targetFrame?.isMainFrame == true && url.path == "/index.html" {
            decisionHandler(.allow); return
        }
        if url.scheme == Schemes.app || url.scheme == Schemes.doc, action.targetFrame?.isMainFrame == false {
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if url.isFileURL { onFileDrop?(url) } else { onLink?(url.absoluteString) }
    }

    // window.open and target=_blank: never a new window, only the link policy.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { onLink?(u.absoluteString) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onMessage?(["type": "crashed"])
    }
}

/// WKUserContentController keeps its handlers strongly; this breaks the cycle.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}
