import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "Daemon")

private enum MTPDaemonActivity {
    case idle, verifying, mounting, unmounting
}

final class MTPDaemon: NSObject {
    let engine = MTPService()

    private let watcher = MTPDeviceWatcher()
    private let queue = DispatchQueue(label: "dev.xinto.mtpfs.mtpd.daemon")

    private var candidate: MTPCandidate?
    private var volumeName: String?
    private var activity: MTPDaemonActivity = .idle

    private var generation: UInt64 = 0

    func start() {
        watcher.delegate = self
        watcher.start()
        queue.async {
            self.reclaimMountsFromPreviousLife()
        }
    }

    private func reclaimMountsFromPreviousLife() {
        for mount in MTPMountTable.current() {
            do {
                try MTPMounter.unmountBestEffort(path: mount.path)
            } catch {
                log.error(
                    """
                    could not reclaim \(mount.path, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
            }
            MTPPathMarker.remove(deviceKey: mount.deviceKey)
            let path = mount.path
            Task { await MTPMounter.cleanupMountpoint(path: path) }
        }
    }
}

extension MTPDaemon: MTPDeviceWatcherDelegate {

    func watcher(_ watcher: MTPDeviceWatcher, didFindCandidate candidate: MTPCandidate) {
        queue.async {
            if self.candidate != nil {
                self.watcher.forget(candidate)
                return
            }
            self.candidate = candidate
            self.activity = .verifying
            self.verify(candidate: candidate)
        }
    }
    
    private static let verifyAttempts = 6
    private static let verifyBackoffs: [TimeInterval] = [0.25, 0.5, 1.0, 1.5, 3.0]

    private func verify(candidate: MTPCandidate, attempt: Int = 0) {
        let generation = self.generation

        engine.openSession { data, error in
            self.queue.async {
                guard generation == self.generation, self.candidate?.entryID == candidate.entryID else {
                    return
                }

                if let error {
                    let next = attempt + 1
                    if next < Self.verifyAttempts {
                        let delay = Self.verifyBackoffs[min(attempt, 4)]
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            guard generation == self.generation, self.candidate?.entryID == candidate.entryID else {
                                return
                            }
                            self.verify(candidate: candidate, attempt: next)
                        }
                        return
                    }

                    log.info(
                        """
                        \(candidate.displayName, privacy: .public) did not open an MTP session after \
                        \(Self.verifyAttempts) attempts, ignoring: \
                        \(String(describing: error), privacy: .public)
                        """
                    )
                    
                    self.activity = .idle
                    self.candidate = nil
                    self.watcher.forget(candidate)
                    return
                }

                self.activity = .idle
                self.volumeName = candidate.displayName
                self.performMount(candidate: candidate, volumeName: candidate.displayName, completion: nil)
            }
        }
    }

    func watcher(_ watcher: MTPDeviceWatcher, didLoseCandidate candidate: MTPCandidate) {
        queue.async {
            if self.candidate?.entryID != candidate.entryID {
                return
            }
            self.generation += 1
            do {
                try self.teardown(deviceKey: candidate.deviceKey, mayEscalate: true)
            } catch {
                log.error("could not unmount departed device: \(String(describing: error), privacy: .public)")
            }
            self.engine.forceCloseSession()
            self.candidate = nil
            self.volumeName = nil
            self.activity = .idle
            self.watcher.rescan()
        }
    }

    private func performMount(
        candidate: MTPCandidate,
        volumeName: String,
        completion: ((Error?) -> Void)?
    ) {
        if let existing = MTPMountTable.mountPoint(forDeviceKey: candidate.deviceKey) {
            activity = .idle
            completion?(nil)
            return
        }

        if activity == .mounting {
            completion?(POSIXError(.EALREADY))
            return
        }

        activity = .mounting
        let generation = self.generation

        Task {
            do {
                let mountURL = try await MTPMounter.mount(
                    volumeName: volumeName,
                    deviceKey: candidate.deviceKey
                )
                self.queue.async {
                    if generation != self.generation {
                        try? MTPMounter.unmountBestEffort(path: mountURL.path)
                        MTPPathMarker.remove(deviceKey: candidate.deviceKey)
                        completion?(POSIXError(.ECANCELED))
                        return
                    }
                    self.activity = .idle
                    log.info("mounted at \(mountURL.path, privacy: .public)")
                    completion?(nil)
                }
            } catch {
                self.queue.async {
                    if generation != self.generation {
                        completion?(POSIXError(.ECANCELED))
                        return
                    }
                    self.activity = .idle
                    log.error("mount failed: \(String(describing: error), privacy: .public)")
                    completion?(error)
                }
            }
        }
    }

    private func teardown(deviceKey: String, mayEscalate: Bool) throws {
        guard let path = MTPMountTable.mountPoint(forDeviceKey: deviceKey) else {
            MTPPathMarker.remove(deviceKey: deviceKey)
            return
        }

        var failure: Error?
        do {
            if mayEscalate {
                try MTPMounter.unmountBestEffort(path: path)
            } else {
                try MTPMounter.unmountPolitely(path: path)
            }
        } catch {
            failure = error
        }

        if MTPMountTable.mountPoint(forDeviceKey: deviceKey) != nil {
            throw failure ?? POSIXError(.EBUSY)
        }

        MTPPathMarker.remove(deviceKey: deviceKey)
        Task { await MTPMounter.cleanupMountpoint(path: path) }
    }
}
