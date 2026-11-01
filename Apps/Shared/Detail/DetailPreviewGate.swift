import Foundation
import Library
import PlaybackCore

/// Det enda stället där detaljsidan beslutar om en förhandsvisning får starta (§6.4, §6.5). Besluten tas av den rena
/// `PreviewPolicy`; den här filen kopplar dem till `PreviewController` så att kopplingen kan testas utan vy.
///
/// tvOS: oförändrat, sidan hävdar förhandsvisningen när den visas. iPhone/iPad: sidan startar aldrig något själv och
/// tar därför aldrig en `max_connections`-plats; bara ett tryck på knappen ("Show Preview") startar, tyst, och bara om
/// profilen har förhandsvisningar på och inte är en barnprofil.
enum DetailPreviewGate {
    /// Plattformen koden körs på (valet görs vid kompilering, aldrig ur enhetstyp).
    static var current: PreviewPlatform {
        #if os(tvOS)
        return .tv
        #else
        return .handheld
        #endif
    }

    /// Detaljsidan (eller dess laddningsläge) visas för `item`. tvOS: titeln hävdas (autostart som förut). Handheld:
    /// ingen start; en eventuell förhandsvisning från en föregående sida stoppas direkt.
    @MainActor
    static func claimOnAppear(_ controller: PreviewController?, item: Library.LibraryItem?, playlistID: UUID,
                              platform: PreviewPlatform = current) {
        if PreviewPolicy.autoStartsOnAppear(platform) {
            controller?.focusChanged(to: item, playlistID: playlistID)
        } else {
            controller?.focusChanged(to: nil, playlistID: playlistID)
        }
    }

    /// Visas knappen "Show Preview"? Bara där autostart saknas och profilen tillåter en användarstartad förhandsvisning.
    static func showsPreviewButton(previewsEnabled: Bool, kids: Bool, platform: PreviewPlatform = current) -> Bool {
        !PreviewPolicy.autoStartsOnAppear(platform)
            && PreviewPolicy.allowsUserStartedPreview(platform, previewsEnabled: previewsEnabled, kids: kids)
    }

    /// Användaren tryckte på "Show Preview". Startar tyst (kontrollern väntar sin vanliga stillastående tid, prövar
    /// åldersfiltret och tar en ledig plats med syftet `.preview`). Returnerar om en start begärdes.
    @MainActor @discardableResult
    static func userStart(_ controller: PreviewController?, item: Library.LibraryItem, playlistID: UUID,
                          previewsEnabled: Bool, kids: Bool, platform: PreviewPlatform = current) -> Bool {
        guard let controller,
              showsPreviewButton(previewsEnabled: previewsEnabled, kids: kids, platform: platform) else { return false }
        controller.setSoundEnabled(false)
        // Efter en tillbakagång till artwork (eller ett stopp) ligger samma fokusnyckel kvar och `focusChanged` vore en
        // no-op: nollställ först så att ett nytt tryck alltid ger ett nytt försök. Synkront, och föregående stängning
        // väntas in av kontrollerns `previousClose`, så ingen lease hålls dubbelt.
        controller.stopNow()
        controller.focusChanged(to: item, playlistID: playlistID)
        return true
    }
}
