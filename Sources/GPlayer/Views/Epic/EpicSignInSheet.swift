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
            HStack {
                if usesBrowser {
                    Button("Use Epic's page here instead") { usesBrowser = false }.buttonStyle(.link)
                } else {
                    Button("Sign in in your browser instead") {
                        NSWorkspace.shared.open(EpicSignIn.browserLoginURL)
                        usesBrowser = true
                    }
                    .buttonStyle(.link)
                }
                Spacer()
            }
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
            Text("Your browser opened Legendary's sign-in page. Sign in there, copy the authorizationCode value from the page it shows, and paste it below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Authorization code", text: $pasted, prompt: Text("Paste the code"))
                .textFieldStyle(.roundedBorder).font(Theme.path)
                .onSubmit(submit)
            HStack {
                Button("Open the Page Again") { NSWorkspace.shared.open(EpicSignIn.browserLoginURL) }
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

/// Epic's login page in a web view that keeps nothing: its website data is gone with the sheet. It tells the page it is the
/// Epic Games Launcher (`EpicSignIn.userAgent`), and looks at two things only: an address on `localhost` with `?code=`, and the
/// text of Epic's redirect page. Nothing is injected into any page, and no address is written to a log.
private struct EpicLoginWebView: NSViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = EpicSignIn.userAgent
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

        /// An address on localhost with a code is where Epic's login can lead instead of the redirect page.
        func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let code = EpicSignIn.code(fromRedirect: url) {
                decisionHandler(.cancel)
                deliver(code)
            } else {
                decisionHandler(.allow)
            }
        }

        /// Epic's redirect page shows a JSON text with the code. Only that page's text is read, and only then.
        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            guard !delivered, EpicSignIn.isRedirectPage(web.url) else { return }
            web.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                if let text = result as? String, let code = EpicSignIn.code(fromPageBody: text) { self?.deliver(code) }
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
