import Foundation

/// What the first-launch prompt should offer.
///
/// Lives here, away from the alert that shows it, because the wrong
/// answer is invisible until somebody installs the app fresh — and the
/// wrong answer shipped once.
///
/// With no default server address, "Log in" has nothing to log in *to*:
/// `OAuthLogin.run` refuses immediately, so the first thing a new user
/// saw was a button that produced an error. Worse, the error named a
/// menu item that had been removed when settings were consolidated, so
/// it pointed at a control that did not exist.
public enum FirstRun {

    public enum Offer: Equatable {
        /// No server address yet. Ask for that before anything else.
        case openSettings
        /// There is an address; the missing piece is a sign-in.
        case logIn
        /// Nothing to ask about.
        case nothing
    }

    public static func offer(for config: AtriumConfig, hasSecret: Bool) -> Offer {
        if config.baseURL.isEmpty { return .openSettings }
        if config.clientID.isEmpty || !hasSecret { return .logIn }
        return .nothing
    }
}
