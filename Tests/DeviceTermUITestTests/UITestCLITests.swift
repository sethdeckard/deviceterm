// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import DeviceTermUITest

@Suite("deviceterm-uitest argv parsing")
struct UITestCLITests {
    @Test("no args and help resolve to usage", arguments: [
        [] as [String],
        ["-h"],
        ["--help"],
        ["help"]
    ])
    func usage(args: [String]) throws {
        #expect(try UITestCLI.parse(args) == .usage)
    }

    @Test
    func serveResolvesToServe() throws {
        #expect(try UITestCLI.parse(["serve"]) == .serve)
    }

    @Test("simple client verbs", arguments: [
        (["ping"], UITestMethod.ping),
        (["doctor"], UITestMethod.doctor)
    ])
    func simpleClientVerbs(args: [String], method: UITestMethod) throws {
        #expect(try UITestCLI.parse(args) == .client(UITestRequest(method: method)))
    }

    @Test
    func captureWindowCarriesOutAndBundleID() throws {
        let command = try UITestCLI.parse(
            ["capture", "window", "--out", "/tmp/a.png", "--bundle-id", "com.deviceterm"]
        )
        #expect(command == .client(UITestRequest(
            method: .captureWindow,
            params: ["out": "/tmp/a.png", "bundleId": "com.deviceterm"]
        )))
    }

    @Test
    func captureWindowRequiresOut() {
        #expect(throws: UITestParseError.self) {
            _ = try UITestCLI.parse(["capture", "window"])
        }
    }

    @Test
    func captureStatusItemCarriesOut() throws {
        let command = try UITestCLI.parse(["capture", "status-item", "--out", "/tmp/d.png"])
        #expect(command == .client(UITestRequest(method: .captureStatusItem, params: ["out": "/tmp/d.png"])))
    }

    @Test
    func axDumpOptionalBundleID() throws {
        #expect(try UITestCLI.parse(["ax", "dump"]) == .client(UITestRequest(method: .axDump)))
        #expect(try UITestCLI.parse(["ax", "dump", "--bundle-id", "x"])
            == .client(UITestRequest(method: .axDump, params: ["bundleId": "x"])))
    }

    @Test
    func driveKeyTakesOneShortcut() throws {
        #expect(try UITestCLI.parse(["drive", "key", "cmd+t"])
            == .client(UITestRequest(method: .driveKey, params: ["shortcut": "cmd+t"])))
        #expect(throws: UITestParseError.self) {
            _ = try UITestCLI.parse(["drive", "key", "cmd+t", "extra"])
        }
    }

    @Test
    func driveClickPointOrAX() throws {
        #expect(try UITestCLI.parse(["drive", "click", "0.5", "0.25"])
            == .client(UITestRequest(method: .driveClick, params: ["x": "0.5", "y": "0.25"])))
        // `--ax` is a label needle (title/description/identifier), not a
        // role path: the driver flat-matches it against the tree.
        #expect(try UITestCLI.parse(["drive", "click", "--ax", "Shut Down Sims"])
            == .client(UITestRequest(method: .driveClick, params: ["ax": "Shut Down Sims"])))
    }

    @Test("malformed drive click is rejected", arguments: [
        ["drive", "click"],
        ["drive", "click", "0.5"],
        ["drive", "click", "left", "right"]
    ])
    func driveClickRejectsBadOperands(args: [String]) {
        #expect(throws: UITestParseError.self) { _ = try UITestCLI.parse(args) }
    }

    @Test
    func unknownVerbThrows() {
        #expect(throws: UITestParseError.self) { _ = try UITestCLI.parse(["frobnicate"]) }
    }
}
