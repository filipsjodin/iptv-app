import SwiftUI

/// Appens få animationer. Systemnära fjädrar och korta övertoningar, inga egna "lekfulla" effekter (anti-mål),
/// och ingen rörelse alls när Minska rörelse är på.
enum Motion {
    /// Fokusbyte och små lägesändringar.
    static let focus: Animation = .spring(response: 0.35, dampingFraction: 0.85)
    /// Övertoning mellan bakgrunder (t.ex. artwork till förhandsvisning).
    static let crossfade: Animation = .easeInOut(duration: 0.4)
    /// Att en bild som laddats tonas in.
    static let imageFadeIn: Animation = .easeOut(duration: 0.18)

    /// `a`, eller `nil` (ingen animation) när Minska rörelse är på.
    static func animation(_ a: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : a
    }
}
