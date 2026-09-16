// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

private func workspaceJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return try #require(String(data: data, encoding: .utf8))
}

private let contractWindow = WorkspaceWindow(
    id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
    shortId: "aaaaaa",
    name: "main",
    index: 1,
    current: true,
    focused: false,
    selectedTabId: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
    tabCount: 1
)

private let contractTab = WorkspaceTab(
    id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
    shortId: "bbbbbb",
    name: "build",
    title: "swift test",
    windowId: contractWindow.id,
    current: true,
    selected: true,
    protected: false,
    state: .ready,
    paneCount: 1
)

private let contractPane = WorkspacePane(
    id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
    shortId: "cccccc",
    name: "shell",
    kind: .terminal,
    tabId: contractTab.id,
    current: true,
    focused: true,
    capabilities: [.sendInput, .captureText],
    terminal: .init(
        sessionId: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
        title: "swift test",
        tty: "/dev/ttys003",
        cwd: "/project"
    )
)

@Test
func workspaceWindowJSONContract() throws {
    let expected = #"{"current":true,"focused":false,"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","#
        + #""index":1,"name":"main","selectedTabId":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","#
        + #""shortId":"aaaaaa","tabCount":1}"#
    #expect(try workspaceJSON(contractWindow) == expected)
}

@Test
func workspaceTabJSONContract() throws {
    let expected = #"{"current":true,"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","name":"build","paneCount":1,"#
        + #""protected":false,"selected":true,"shortId":"bbbbbb","state":"ready","title":"swift test","#
        + #""windowId":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}"#
    #expect(try workspaceJSON(contractTab) == expected)
}

@Test
func workspaceTerminalPaneJSONContract() throws {
    let expected = #"{"capabilities":["sendInput","captureText"],"current":true,"focused":true,"#
        + #""id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","kind":"terminal","name":"shell","#
        + #""shortId":"cccccc","tabId":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","#
        + #""terminal":{"cwd":"\/project","sessionId":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","#
        + #""title":"swift test","tty":"\/dev\/ttys003"}}"#
    #expect(try workspaceJSON(contractPane) == expected)
}

@Test
func workspaceTerminalPaneOmitsUnknownWorkingDirectory() throws {
    let pane = WorkspacePane(
        id: contractPane.id,
        shortId: contractPane.shortId,
        name: contractPane.name,
        kind: .terminal,
        tabId: contractPane.tabId,
        current: contractPane.current,
        focused: contractPane.focused,
        capabilities: contractPane.capabilities,
        terminal: .init(
            sessionId: contractPane.id,
            title: "swift test",
            tty: "/dev/ttys003",
            cwd: nil
        )
    )
    let encoded = try workspaceJSON(pane)
    #expect(encoded.contains(#""sessionId":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC""#))
    #expect(!encoded.contains(#""cwd""#))
}

/// A pane whose surface has not attached carries no tty, while the label it
/// already has survives. The two travel separately on purpose: absence of
/// `tty` is transient, and a consumer must not read it as "unsupported".
@Test
func workspaceTerminalPaneOmitsUnknownTTYButKeepsTitle() throws {
    let pane = WorkspacePane(
        id: contractPane.id,
        shortId: contractPane.shortId,
        name: contractPane.name,
        kind: .terminal,
        tabId: contractPane.tabId,
        current: contractPane.current,
        focused: contractPane.focused,
        capabilities: contractPane.capabilities,
        terminal: .init(
            sessionId: contractPane.id,
            title: "shell",
            tty: nil,
            cwd: nil
        )
    )
    let encoded = try workspaceJSON(pane)
    #expect(encoded.contains(#""title":"shell""#))
    #expect(!encoded.contains(#""tty""#))
    #expect(!encoded.contains(#""cwd""#))
}

/// A terminal object built before `title` existed still decodes. The wire
/// version did not move for the field, so a CLI from a newer bundle can be
/// handed one by a GUI from an older one after a mid-session update, and a
/// human-mode command whose response contains a terminal pane decodes this
/// type.
@Test
func workspaceTerminalPaneDecodesWithoutATitle() throws {
    let json = #"{"sessionId":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","cwd":"\/project"}"#
    let terminal = try JSONDecoder().decode(
        WorkspacePane.Terminal.self,
        from: Data(json.utf8)
    )
    #expect(terminal.sessionId == "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
    #expect(terminal.title == WorkspacePane.Terminal.defaultTitle)
    #expect(terminal.tty == nil)
    #expect(terminal.cwd == "/project")
}

@Test
func workspaceTerminalPaneRoundTripsEveryField() throws {
    let encoded = try workspaceJSON(contractPane)
    let decoded = try JSONDecoder().decode(WorkspacePane.self, from: Data(encoded.utf8))
    #expect(decoded == contractPane)
}

@Test
func workspaceLayoutUsesExplicitTaggedNodes() throws {
    let layout = WorkspaceLayoutNode.split(
        axis: "horizontal",
        extents: [0.4, 0.6],
        children: [.pane(id: "P1"), .pane(id: "P2")]
    )
    let expected = #"{"axis":"horizontal","children":[{"paneId":"P1","type":"pane"},"#
        + #"{"paneId":"P2","type":"pane"}],"extents":[0.4,0.6],"type":"split"}"#
    #expect(try workspaceJSON(layout) == expected)
    #expect(try JSONDecoder().decode(WorkspaceLayoutNode.self, from: JSONEncoder().encode(layout)) == layout)
}

@Test
func workspaceDetailAndCaptureJSONContracts() throws {
    let detail = WorkspaceTabDetail(
        tab: contractTab,
        panes: [contractPane],
        layout: .pane(id: contractPane.id)
    )
    let encoded = try workspaceJSON(detail)
    #expect(encoded.contains(#""layout":{"paneId":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","type":"pane"}"#))
    #expect(encoded.contains(#""panes":[{"capabilities":["sendInput","captureText"]"#))
    #expect(encoded.contains(#""tab":{"current":true"#))

    let capture = WorkspaceCaptureResult(pane: contractPane, text: "one\ntwo")
    let captureJSON = try workspaceJSON(capture)
    #expect(captureJSON.contains(#""text":"one\ntwo""#))
    #expect(captureJSON.contains(#""pane":{"capabilities":["sendInput","captureText"]"#))

    // A styled capture rides the same `text` field. ESC has no shorthand
    // escape in JSON, so it encodes as \u001b and must survive intact:
    // a consumer stripping SGR needs the bytes it was sent.
    let styled = WorkspaceCaptureResult(
        pane: contractPane,
        text: "\u{1b}[31mred\u{1b}[0m\n"
    )
    let styledJSON = try workspaceJSON(styled)
    #expect(styledJSON.contains(#""text":"\u001b[31mred\u001b[0m\n""#))
    #expect(
        try JSONDecoder().decode(
            WorkspaceCaptureResult.self,
            from: Data(styledJSON.utf8)
        ) == styled
    )
}

@Test
func workspaceMutationReceiptCarriesCommittedObjects() throws {
    let receipt = WorkspaceMutationReceipt(
        window: contractWindow,
        tab: contractTab,
        pane: contractPane,
        bytes: 5,
        typeDelayMs: 8
    )
    let encoded = try workspaceJSON(receipt)
    #expect(encoded.contains(#""bytes":5"#))
    #expect(encoded.contains(#""ok":true"#))
    #expect(encoded.contains(#""pane":{"capabilities":["sendInput","captureText"]"#))
    #expect(encoded.contains(#""tab":{"current":true"#))
    #expect(encoded.contains(#""typeDelayMs":8"#))
    #expect(encoded.contains(#""window":{"current":true"#))

    let closed = WorkspaceMutationReceipt(
        closed: .init(resource: "pane", pane: contractPane),
        mode: .shutdown
    )
    let closedJSON = try workspaceJSON(closed)
    #expect(closedJSON.contains(#""closed":{"pane":{"capabilities"#))
    #expect(closedJSON.contains(#""resource":"pane"#))
    #expect(closedJSON.contains(#""mode":"shutdown"#))
    #expect(!closedJSON.contains(#""window"#))
}
