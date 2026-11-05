import Foundation
import Darwin

/// A dedicated Pause command, never the toggle Play/Pause command. It cannot
/// start a track that was already paused. No now-playing metadata is requested.
enum SystemMedia {
    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> Bool
    private static let framework: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)
    private static let send: SendCommand? = {
        guard let framework, let symbol = dlsym(framework, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    @discardableResult static func pause() -> Bool {
        // MediaRemote command 1 = Pause, 0 = Play, 2 = TogglePlayPause.
        // Private API: absence/failure is nonfatal; dictation must remain usable.
        send?(1, nil) ?? false
    }
}
