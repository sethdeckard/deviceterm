// SPDX-License-Identifier: GPL-3.0-or-later
/// The narrow role the daemon depends on to drive device input: report what the
/// device supports, and perform one intent at a time.
///
/// `support` is fixed at construction, so it is a synchronous requirement.
/// `perform` is async because delivering a report crosses the tunnel; the
/// concrete relay guarantees intents on the same surface stay ordered.
package protocol InteractionRelaying: Sendable {
    var support: InteractionSupport { get }

    @discardableResult
    func perform(_ intent: InteractionIntent) async throws -> InteractionOutcome
}
