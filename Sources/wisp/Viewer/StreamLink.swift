// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon

/// What a viewer window needs from whatever carries its stream: the `Client` itself when the window
/// lives in the process holding the connection, or the relay to the main Wisp process when it lives
/// in a phantom app (docs/multi-window.md §5). Any thread.
protocol StreamLink: AnyObject {
    /// An input message for `stream` (built with `message(_:stream:)`); `discrete` = a click or key press worth timing.
    func sendInput(_ stream: UInt16, _ d: Data, discrete: Bool)
    func resizeWindow(_ stream: UInt16, _ size: CGSize, id: UInt32)
    /// Stop receiving `stream`; the window stays open on the host.
    func closeStream(_ stream: UInt16)
    /// Close `stream`'s window on the host.
    func closeRemoteWindow(_ stream: UInt16)
    /// The windows' screen may have changed: tell the host its size.
    func sendScreen()
    /// A frame went on screen (for the latency figures).
    func frameDisplayed(_ t: FrameTiming)
}

/// A stream as a viewer window sees it: `RemoteStream` (in-process) or `PhantomStream` (in a phantom app).
/// Info, chrome, gone and closed arrive on the main queue, images on a background queue; what arrived
/// before `attach` is replayed at once.
protocol ViewerStream: AnyObject {
    var id: UInt16 { get }
    var windowID: UInt32 { get }
    func attach(info: ((RemoteInfo) -> Void)?, chrome: ((WindowChrome) -> Void)?, gone: (() -> Void)?,
                closed: (() -> Void)?, image: ((CVPixelBuffer, FrameTiming) -> Void)?)
    func detach()
}

/// Whoever owns a set of viewer windows: the in-process `ViewerSession`, or a phantom app.
protocol WindowOwner: AnyObject {
    var hostName: String { get }
    var link: StreamLink { get }
    /// Places a window about to be shown for the first time.
    func placeNew(_ c: ViewerController)
    /// A window closed (it already told the host, if it had to).
    func controllerClosed(_ c: ViewerController)
}

extension WindowOwner {
    /// Centred if it's the only window, else cascaded from the frontmost other one.
    func place(_ c: ViewerController, among all: [ViewerController]) {
        let others = all.filter { $0 !== c && $0.window.isVisible }
        guard let front = others.first(where: { $0.window.isKeyWindow }) ?? others.last else { c.window.center(); return }
        let next = front.window.cascadeTopLeft(from: .zero)
        c.window.cascadeTopLeft(from: next)
    }
}

/// The per-window line in the title: latency, traffic, this stream's frame rate and repairs.
func statsLine(latency lat: String, down: Int, up: Int, frames: Int, repaired: Int) -> String {
    "\(lat.isEmpty ? "" : lat + "  ·  ")↓ \(kbps(down, over: 1))  ↑ \(kbps(up, over: 1))  \(frames) fps\(repaired > 0 ? "  \(repaired) pkts repaired" : "")"
}
