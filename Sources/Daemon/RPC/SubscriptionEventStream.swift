// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a subscription handler hands the dispatcher to read events from.
///
/// Two shapes, because the handlers disagree about where the buffer belongs.
/// Most push into an `AsyncStream` and let the dispatcher drain it. `pane.
/// subscribe` instead vends a pull closure reading the coordinator's
/// conflating channel directly, which keeps that channel the only handler-side
/// event buffer; an `AsyncStream` in front of it would accept every yield no
/// matter what the transport was doing, and the conflation would just move the
/// pile-up a hop downstream.
///
/// A hand-written erasure rather than `any AsyncSequence<Element, Failure>`,
/// which needs macOS 15 and this package targets 14.
public struct SubscriptionEventStream: AsyncSequence, Sendable {
    public typealias Element = MethodRegistry.SubscriptionEvent

    private enum Source: Sendable {
        case stream(AsyncStream<Element>)
        case pull(@Sendable () async -> Element?)
    }

    public struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<Element>.Iterator?
        let pull: (@Sendable () async -> Element?)?

        public mutating func next() async -> Element? {
            if let pull { return await pull() }
            return await base?.next()
        }
    }

    private let source: Source

    public init(_ stream: AsyncStream<Element>) {
        source = .stream(stream)
    }

    /// `next` must return nil once the subscription finishes, matching what a
    /// stream's iterator does at the end. Nothing here enforces it.
    public init(pulling next: @escaping @Sendable () async -> Element?) {
        source = .pull(next)
    }

    public func makeAsyncIterator() -> Iterator {
        switch source {
        case let .stream(stream):
            return Iterator(base: stream.makeAsyncIterator(), pull: nil)

        case let .pull(next):
            return Iterator(base: nil, pull: next)
        }
    }
}
