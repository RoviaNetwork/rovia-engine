import Foundation
import LibXray
import RoviaXray

/// The one place the gomobile-built `LibXray` module is touched.
///
/// Memory contract, stated because the protocol was shaped on the cgo bridge:
/// gomobile returns an autoreleased `NSString` that Swift bridges to `String`,
/// so there is no buffer to free — the Go runtime's reference is released by
/// the generated glue when the Objective-C object dies. `free(_:)` is
/// therefore a deliberate no-op here, and the protocol's documentation names
/// both memory models.
public struct GomobileLibXrayBridge: LibXrayBridge {
    public init() {}

    public func invoke(_ requestJSON: String) throws -> String {
        LibXrayInvoke(requestJSON)
    }

    public func free(_ response: String) {
        // See the type documentation: the gomobile memory model has no
        // explicit free.
    }
}
