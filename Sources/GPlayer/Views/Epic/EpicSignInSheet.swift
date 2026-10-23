import AppKit
import GPlayerCore
import SwiftUI
import WebKit

/// Signing in to Epic Games. The user signs in on Epic's own page, shown here; the sheet only waits for the page Epic sends the
/// browser to afterwards and takes the one-time code from it. The password, or whatever else is typed on Epic's page, is never
/// read: nothing here touches a form. Or the user signs in in their own browser and pastes the code.
struct EpicSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var usesBrowser = false
    @State private var pasted = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Epic Games").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if usesBrowser {
                BrowserSignIn(pasted: $pasted, finish: finish)
            } else {
                EpicLoginWebView(onCode: finish)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if usesBrowser {
                    Button("Use Epic's page here instead") { usesBrowser = false }.buttonStyle(.link)
                } else {
                    // Doesn't open anything: the next screen says what legendary.gl is, and opens it on a button of its own.
                    Button("Sign in in your browser instead") { usesBrowser = true }.buttonStyle(.link)
                }
                Text("Legendary keeps your sign-in token in your G-Player library folder. A library on an exFAT, network or iCloud disk can't keep it private.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: 500, height: 560)
    }

    /// The code is handed over and the sheet closes; the sign-in itself goes on in the sidebar.
    private func finish(_ code: String) {
        pasted = ""
        model.finishEpicSignIn(code: code)
    }
}

/// The browser way: Legendary's page shows the code after sign-in; the user copies it here.
private struct BrowserSignIn: View {
    @Binding var pasted: String
    let finish: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("legendary.gl is a helper page by Legendary's authors, not by Epic. It sends you to Epic's sign-in and then shows the code Epic gives. Open it in your browser, sign in there, copy the authorizationCode value from the page, and paste it below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Authorization code", text: $pasted, prompt: Text("Paste the code"))
                .textFieldStyle(.roundedBorder).font(Theme.path)
                .onSubmit(submit)
            HStack {
                Button("Open legendary.gl") { NSWorkspace.shared.open(EpicSignIn.browserLoginURL) }
                Spacer()
                Button("Sign In", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(EpicSignIn.code(fromPasted: pasted) == nil)
            }
            Spacer()
        }
        .padding(18)
    }

    private func submit() {
        if let code = EpicSignIn.code(fromPasted: pasted) { finish(code) }
    }
}

/// Epic's login page in a web view that keeps nothing: its website data is gone with the sheet. It tells Epic's own pages it is the
/// Epic Games Launcher (`EpicSignIn.userAgent`; Google's and Apple's pages get the browser's own name), and looks at two things only,
/// both of the page itself and never of a frame inside it: an address on `localhost` with `?code=`, and the text of Epic's redirect
/// page. Nothing is injected into any page, and no address is written to a log.
private struct EpicLoginWebView: NSViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = EpicSignIn.userAgent                    // for Epic's own page; the coordinator takes it off for the others
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: EpicSignIn.loginURL))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        /// An address on localhost with a code is where Epic's login can lead instead of the redirect page, but only for the page
        /// itself. And the page about to load is told what the browser is: the launcher for Epic's own, the default for the rest.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isMainFrame = action.targetFrame?.isMainFrame == true
            if let url = action.request.url, let code = EpicSignIn.code(navigatingTo: url, isMainFrame: isMainFrame) {
                decisionHandler(.cancel)
                deliver(code)
                return
            }
            if isMainFrame { web.customUserAgent = EpicSignIn.usesLauncherAgent(for: action.request.url) ? EpicSignIn.userAgent : nil }
            decisionHandler(.allow)
        }

        /// Epic's redirect page shows a JSON text with the code. Only that page's text is read, and only then. (This is called for
        /// the page itself, not for the frames inside it.)
        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, EpicSignIn.isRedirectPage(web.url) else { return }
            let address = web.url
            web.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                if let text = result as? String, let code = EpicSignIn.code(fromPage: address, isMainFrame: true, text: text) { self?.deliver(code) }
            }
        }

        /// A sign-in with Google or Apple may ask for a new window: its page opens in this one.
        func webView(_ web: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { web.load(action.request) }
            return nil
        }

        private func deliver(_ code: String) {
            guard !delivered else { return }
            delivered = true
            DispatchQueue.main.async { self.onCode(code) }
        }
    }
}
