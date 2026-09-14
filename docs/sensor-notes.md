# Lid-angle sensor

MacDuo reads an Apple HID sensor through IOKit. The device-specific format is undocumented and may vary by MacBook model or macOS release. Availability is established by successfully reading a valid angle, rather than inferred from the model name.

The report format was identified by [Sam Henri Gold's LidAngleSensor project](https://github.com/samhenrigold/LidAngleSensor). That project documents compatibility problems with the M1 MacBook Air and M1/M2 MacBook Pro models with Touch Bar. It is a research reference; MacDuo does not bundle the original utility.

## Device and report format

| Field | Value |
| --- | --- |
| Apple vendor ID | `0x05AC` |
| Primary usage page | `0x0020` (sensor) |
| Primary usage | `0x008A` |
| Preferred product ID | `0x8104` |
| Feature report ID | `1` |
| Angle | Bytes 1–2, unsigned 16-bit little-endian degrees |

The reader allocates an eight-byte buffer and accepts only successful reports containing at least three bytes, report ID `1`, and an angle in the inclusive range 0–180°. Other product IDs may work if they expose the same usage and a valid report.

## Threading and recovery

[`IOHIDDeviceGetReport`](https://developer.apple.com/documentation/iokit/1588659-iohiddevicegetreport) blocks until the device returns a report. Discovery, opening, polling at approximately 60 Hz, and closing therefore run on a dedicated serial queue. The HID manager is used for discovery; MacDuo opens only the selected device, without exclusive access.

`start()`, `stop()`, and callback assignment happen on the main thread. Callbacks arrive on the main queue, with generation checks discarding events queued before a stop. Unchanged angles are not delivered repeatedly.

Three consecutive read failures close the device and schedule rediscovery. When no device is present, discovery is retried about every two seconds. Sensor loss invalidates any active desktop snapshot. The app never substitutes simulated measurements for actual sensor readings; the preview's manual angle is separate.

MacDuo runs outside the App Sandbox. The existing local verification below did not require administrator privileges or Input Monitoring access. This is not a compatibility guarantee for other hardware.

## Recorded hardware verification

The original development notes record a successful read on September 12, 2026:

| Item | Recorded result |
| --- | --- |
| Model identifier | `Mac16,13` |
| macOS | `26.6.2` (`25G83`) |
| Device | Apple SPU HID sensor |
| Measured angle | `35°` |
| Access | Normal user; callback on the main thread |

This is a historical observation, not a test rerun or a list of all supported models. To check another Mac without capturing its screen, build the app and run:

```sh
dist/MacDuo.app/Contents/MacOS/MacDuo --diagnose
```
