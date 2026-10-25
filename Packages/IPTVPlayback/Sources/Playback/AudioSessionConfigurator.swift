import AVFoundation

public enum AudioSessionConfigurator {
    /// Ljudsession för film/TV: kategori `.playback`, läge `.moviePlayback`, flerkanal där det stöds.
    public static func configureForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(tvOS)
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        #else
        try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
        #endif
        // Flerkanal/rumsligt ljud (t.ex. Atmos via HDMI/AirPlay); inte fatalt om routen saknar stöd.
        try? session.setSupportsMultichannelContent(true)
        try session.setActive(true)
    }
}
