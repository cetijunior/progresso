import Foundation
import CoreServices

/// Watches a board folder with FSEvents and fires (debounced) when anything
/// inside changes — so edits made in Obsidian appear without pressing ⌘R.
///
/// Events under `.git/` are ignored: on git-synced boards our own
/// commit/pull/push cycle churns dozens of .git files every sync, and firing
/// on those rebuilt the whole board mid-interaction (cards recreated under
/// the user's cursor — the "tickets become uneditable" bug).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init?(path: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString.
            let paths = Unmanaged<CFArray>.fromOpaque(
                UnsafeRawPointer(eventPaths)).takeUnretainedValue() as? [String] ?? []
            let relevant = paths.contains { path in
                !path.contains("/.git/") && !path.hasSuffix("/.git")
            }
            if relevant || numEvents == 0 {
                watcher.fire()
            }
        }
        guard let s = FSEventStreamCreate(
            nil, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                     | kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    deinit { stop() }
}
