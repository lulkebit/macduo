import Foundation
import IOKit.hid

/// Reads the MacBook's built-in hinge sensor without taking exclusive access.
/// Configure callbacks and call start/stop on the main thread. HID operations
/// run on a serial worker queue; every callback arrives on the main thread.
final class LidAngleSensor {
    enum Status: Equatable {
        case connected(String)
        case unavailable(String)
    }

    var onAngle: ((Double) -> Void)?
    var onStatus: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "com.macduo.lid-angle", qos: .userInteractive)
    private var reader: Reader?
    private var generation = 0

    func start() {
        precondition(Thread.isMainThread)
        guard reader == nil else { return }
        generation += 1
        let currentGeneration = generation
        let worker = Reader { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration,
                      self.reader != nil else { return }
                switch event {
                case .angle(let angle): self.onAngle?(angle)
                case .status(let status): self.onStatus?(status)
                }
            }
        }
        reader = worker
        queue.async { [queue] in worker.start(on: queue) }
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        guard let worker = reader else { return }
        reader = nil
        queue.async { worker.stop() }
    }

    deinit {
        if let worker = reader {
            queue.async { worker.stop() }
        }
    }

    private enum Event {
        case angle(Double)
        case status(Status)
    }

    /// All mutable state below is confined to the worker queue.
    private final class Reader {
        private let emit: (Event) -> Void
        private var timer: DispatchSourceTimer?
        private var manager: IOHIDManager?
        private var device: IOHIDDevice?
        private var nextDiscovery: TimeInterval = 0
        private var failures = 0
        private var previousAngle: Double?
        private var previousStatus: Status?

        init(emit: @escaping (Event) -> Void) {
            self.emit = emit
        }

        func start(on queue: DispatchQueue) {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }

        func stop() {
            timer?.cancel()
            timer = nil
            closeDevice()
        }

        private func poll() {
            guard let device else {
                let now = ProcessInfo.processInfo.systemUptime
                guard now >= nextDiscovery else { return }
                nextDiscovery = now + 2
                discover()
                return
            }

            switch readAngle(from: device) {
            case .success(let angle):
                failures = 0
                deliver(angle)
            case .failure(let error):
                failures += 1
                // Brief transient reads around sleep must not leave a stale
                // overlay running indefinitely. Reconnect after three failures.
                if failures >= 3 {
                    closeDevice()
                    setStatus(.unavailable(error.localizedDescription))
                    nextDiscovery = ProcessInfo.processInfo.systemUptime + 1
                }
            }
        }

        private func discover() {
            closeDevice()
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            let matching: [String: Any] = [
                kIOHIDVendorIDKey: 0x05AC,
                kIOHIDPrimaryUsagePageKey: 0x0020,
                kIOHIDPrimaryUsageKey: 0x008A
            ]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

            // Enumerating does not require IOHIDManagerOpen. Open only the
            // sensor itself: opening the whole manager can require privileges.
            guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
                  !devices.isEmpty else {
                setStatus(.unavailable("No readable lid angle sensor found."))
                return
            }

            // Prefer the known Apple SPU sensor, while allowing future product
            // IDs that expose the same sensor usage and valid report format.
            let candidates = devices.sorted { lhs, rhs in
                let left = (IOHIDDeviceGetProperty(lhs, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
                let right = (IOHIDDeviceGetProperty(rhs, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
                return left == 0x8104 && right != 0x8104
            }
            var lastError = "Could not open the lid angle sensor."
            for candidate in candidates {
                let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                guard result == kIOReturnSuccess else {
                    lastError = "Sensor access failed (\(Self.describe(result)))."
                    continue
                }
                switch readAngle(from: candidate) {
                case .success(let angle):
                    device = candidate
                    failures = 0
                    let product = IOHIDDeviceGetProperty(candidate, kIOHIDProductKey as CFString) as? String
                    setStatus(.connected(product ?? "MacBook lid angle sensor"))
                    deliver(angle)
                    return
                case .failure(let error):
                    lastError = error.localizedDescription
                    IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                }
            }
            setStatus(.unavailable(lastError))
        }

        private func readAngle(from device: IOHIDDevice) -> Result<Double, SensorError> {
            var report = [UInt8](repeating: 0, count: 8)
            var length = CFIndex(report.count)
            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
            guard result == kIOReturnSuccess else {
                return .failure(SensorError(message: "Could not read the sensor (\(Self.describe(result)))."))
            }
            guard length >= 3, report[0] == 1 else {
                return .failure(SensorError(message: "Unknown sensor data format."))
            }
            // Feature report 1: report ID followed by a little-endian degree
            // value. This undocumented format was identified by Sam Henri Gold.
            let degrees = Int(report[1]) | (Int(report[2]) << 8)
            guard (0...180).contains(degrees) else {
                return .failure(SensorError(message: "Invalid lid angle: \(degrees)°."))
            }
            return .success(Double(degrees))
        }

        private func deliver(_ angle: Double) {
            guard angle != previousAngle else { return }
            previousAngle = angle
            emit(.angle(angle))
        }

        private func setStatus(_ status: Status) {
            guard status != previousStatus else { return }
            previousStatus = status
            emit(.status(status))
        }

        private func closeDevice() {
            if let device {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            device = nil
            manager = nil
            previousAngle = nil
            failures = 0
        }

        private static func describe(_ result: IOReturn) -> String {
            String(format: "0x%08x", UInt32(bitPattern: result))
        }
    }

    private struct SensorError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
