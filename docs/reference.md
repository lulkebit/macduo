# Projection design

MacDuo renders a perspective-compensated screenshot on a moving MacBook display. The effect is calculated for a fixed virtual eye position and a fixed reference plane at the configured open angle. It is a screen illusion: the display does not become transparent, and moving your head changes the perceived alignment.

## Geometry

The hinge is the horizontal axis at the bottom of the display. Distances are measured in display heights: the default eye position is 1.5 units above and 3 units in front of the hinge.

For each point on the moving screen, a ray from the virtual eye intersects the fixed reference plane. That intersection identifies the point to sample from the screenshot. The inverse mapping determines the four destination corners used by the perspective transform. The bottom edge remains anchored at the hinge.

The **Display** preview shows this compensated image. The **Observer** preview projects it back through the physical display geometry, showing the apparent result from the virtual eye. Its dashed outline marks the reference plane.

The default eye position sees the display edge-on at about 26.6°. Before reaching that angle, the image fades to an opaque matte. Invalid geometry and areas beyond the finite screenshot also produce a matte, preventing mirrored images, unbounded stretching, or exposure of the live desktop beneath the overlay.

Softness combines a blur that increases toward the moving edge with a subtle neutral veil. Setting it to zero preserves the geometric effect. The physical angle drives the effect in both directions; brief smoothing removes discrete sensor steps without introducing a timed animation.

The [projection tests](../Tests/MacDuoTests/FoldProjectionTests.swift) and [image filter tests](../Tests/MacDuoTests/GlassImageFilterTests.swift) check the production geometry and filter against independently calculated ray/plane intersections.

## Capture lifecycle

Enabling the effect establishes a sensor baseline. A fold starts only when the lid is at least 2° below the configured open angle and has moved at least 2° from its baseline. One screenshot supplies the entire session; stopping or reversing the lid reuses that image.

Reaching the open angle releases the image. Pausing, sleep, screen lock, session changes, sensor failure, and display changes also invalidate it. Resuming establishes a fresh baseline before another physical movement can trigger capture. Non-permission capture failures suppress movement-triggered retries until the lid returns to the open angle or the user explicitly tests access. Permission denials persist independently of the fold gate, including across launches, and block automatic requests until an explicit access test succeeds. Returning from System Settings never triggers a capture. A real denial from a cancelled request still blocks queued folds; stale successful results are discarded.

The overlay is excluded from capture, ignores mouse events, and appears only after its first rendered frame is ready. macOS controls capture permission and capture indicators. Permission tests are separate single-image requests; they discard their image immediately.

## API references

These are the public APIs used by the implementation. Apple's documentation does not define MacDuo's projection model or the device-specific lid-sensor report format.

- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager): captures an individual image. MacDuo calls `captureImage` once per fold session and does not create an `SCStream`.
- [SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:excludingapplications:exceptingwindows:)): excludes MacDuo's windows from the selected display capture.
- [CIPerspectiveTransform](https://developer.apple.com/documentation/coreimage/ciperspectivetransform): applies the destination quadrilateral calculated from the eye and hinge geometry.
- [CGDisplayIsBuiltin](https://developer.apple.com/documentation/coregraphics/cgdisplayisbuiltin(_:)): identifies the internal display independently of which display currently hosts the active window.
- [NSWorkspace.screensDidSleepNotification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification): one of the workspace events used to release the overlay and its image when the display sleeps.
- [IOHIDDeviceGetReport](https://developer.apple.com/documentation/iokit/1588659-iohiddevicegetreport): synchronously retrieves the feature report on the sensor's worker queue. See [sensor notes](sensor-notes.md).
