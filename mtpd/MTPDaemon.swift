import Foundation
import os

private let log = Logger(subsystem: "dev.xinto.mtpfs.mtpd", category: "Daemon")

private enum MTPDaemonActivity {
    case idle
    case verifying
    case mounting
    case unmounting
}

final class MTPDaemon: NSObject {
    let engine = MTPService()

    private let watcher = MTPDeviceWatcher()
    private let queue = DispatchQueue(label: "dev.xinto.mtpfs.mtpd.daemon")

    private var candidate: MTPCandidate?
    private var pendingCandidates: [MTPCandidate] = []

    private var volumeName: String?
    private var activity: MTPDaemonActivity = .idle

    private var generation: UInt64 = 0

    func start() {
        watcher.delegate = self
        engine.onDeviceLost = { [weak self] in
            self?.handleDeviceLost()
        }
        watcher.start()
        queue.async {
            self.reclaimMountsFromPreviousLife()
        }
    }

    private func handleDeviceLost() {
        queue.async {
            guard let candidate = self.candidate else {
                return
            }

            #if DEBUG
            log.info("\(candidate.displayName, privacy: .public) stopped responding")
            #endif
            
            self.generation += 1
            do {
                try self.teardown(deviceKey: candidate.deviceKey, mayEscalate: true)
            } catch {
                log.error("could not unmount lost device: \(String(describing: error), privacy: .public)")
            }
            self.candidate = nil
            self.volumeName = nil
            self.activity = .idle
            self.watcher.forget(candidate)
            self.advanceToNextCandidate()
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
            Task {
                await MTPMounter.cleanupMountpoint(path: path)
            }
        }
    }

    private func startVerify(candidate: MTPCandidate) {
        self.candidate = candidate
        self.activity = .verifying
        
        if candidate.initialVerifyDelay <= 0 {
            verify(candidate: candidate)
            return
        }
        
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + candidate.initialVerifyDelay) {
            guard generation == self.generation, self.candidate?.entryID == candidate.entryID else {
                return
            }
            self.verify(candidate: candidate)
        }
    }
}

extension MTPDaemon: MTPDeviceWatcherDelegate {

    func watcher(_ watcher: MTPDeviceWatcher, didFindCandidate candidate: MTPCandidate) {
        queue.async {
            if self.candidate != nil {
                self.pendingCandidates.append(candidate)
                return
            }
            self.startVerify(candidate: candidate)
        }
    }
    
    private func verify(candidate: MTPCandidate) {
        let generation = self.generation

        engine.openSessionForDevice(vendorID: candidate.vendorID, productID: candidate.productID) { data, error in
            self.queue.async {
                guard generation == self.generation, self.candidate?.entryID == candidate.entryID else {
                    return
                }

                if let error {
                    #if DEBUG
                    log.info(
                        """
                        \(candidate.displayName, privacy: .public) did not open an MTP session: \(String(describing: error), privacy: .public)
                        """
                    )
                    #endif

                    self.activity = .idle
                    self.candidate = nil
                    self.advanceToNextCandidate()
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
            if let idx = self.pendingCandidates.firstIndex(where: { $0.entryID == candidate.entryID }) {
                self.pendingCandidates.remove(at: idx)
                
                #if DEBUG
                log.info("\(candidate.displayName, privacy: .public) disconnected while pending")
                #endif
                
                return
            }

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

            self.advanceToNextCandidate()
        }
    }

    private func advanceToNextCandidate() {
        if let next = pendingCandidates.first {
            pendingCandidates.removeFirst()
            startVerify(candidate: next)
        } else {
            queue.asyncAfter(deadline: .now() + 1.0) {
                self.watcher.rescan()
            }
        }
    }

    private static let mountMaxAttempts = 4
    private static let mountRetryDelays: [TimeInterval] = [2.0, 5.0, 10.0]

    private func performMount(
        candidate: MTPCandidate,
        volumeName: String,
        attempt: Int = 0,
        completion: ((Error?) -> Void)?
    ) {
        if MTPMountTable.mountPoint(forDeviceKey: candidate.deviceKey) != nil {
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
                    
                    #if DEBUG
                    log.info("mounted at \(mountURL.path, privacy: .public)")
                    #endif
                    
                    completion?(nil)
                }
            } catch {
                self.queue.async {
                    if generation != self.generation {
                        completion?(POSIXError(.ECANCELED))
                        return
                    }
                    
                    self.activity = .idle
                    let next = attempt + 1
                    if next < Self.mountMaxAttempts {
                        let delay = Self.mountRetryDelays[min(attempt, Self.mountRetryDelays.count - 1)]
                        
                        #if DEBUG
                        log.warning(
                            """
                            mount failed (attempt \(next)/\(Self.mountMaxAttempts)), \
                            retrying in \(delay)s: \(String(describing: error), privacy: .public)
                            """
                        )
                        #endif
                        
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            guard generation == self.generation, self.candidate?.entryID == candidate.entryID else {
                                return
                            }
                            self.performMount(candidate: candidate, volumeName: volumeName, attempt: next, completion: completion)
                        }
                    } else {
                        log.error("mount failed after \(Self.mountMaxAttempts) attempts: \(String(describing: error), privacy: .public)")
                        completion?(error)
                    }
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
        
        Task {
            await MTPMounter.cleanupMountpoint(path: path)
        }
    }
}
