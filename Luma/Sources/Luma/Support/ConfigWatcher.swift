import Foundation

/// Watches the config directory and fires when its files change on disk, so
/// hand-edits to settings.json / profiles.json apply live — the config file
/// becomes a scripting surface (`jq` + a save). No polling.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let fd: Int32
    private let onChange: () -> Void

    init?(directory: URL, onChange: @escaping () -> Void) {
        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        self.onChange = onChange
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        src.setEventHandler { [weak self] in self?.onChange() }
        src.setCancelHandler { [fd] in close(fd) }
        source = src
        src.resume()
    }

    deinit {
        source?.cancel()
    }
}
