import XCTest
@testable import PoseDeckCore

/// Edge-case coverage for the pure ``SSEParser`` (M3 plan, STEP 9): multi-line
/// data, comment/keep-alive lines, split chunks, CRLF, event/id fields.
final class SSEParserTests: XCTestCase {

    func testSingleSimpleEvent() {
        var p = SSEParser()
        let events = p.feed(text: "data: hello\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello")
        XCTAssertEqual(events[0].event, "message")
    }

    func testEventAndIdFields() {
        var p = SSEParser()
        let events = p.feed(text: "event: PB_CONNECT\nid: 42\ndata: {\"clientId\":\"x\"}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "PB_CONNECT")
        XCTAssertEqual(events[0].id, "42")
        XCTAssertEqual(events[0].data, "{\"clientId\":\"x\"}")
    }

    func testMultiLineDataJoinedByNewline() {
        var p = SSEParser()
        let events = p.feed(text: "data: line1\ndata: line2\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2")
    }

    func testCommentLinesAreIgnored() {
        var p = SSEParser()
        // A keep-alive comment then a real event.
        let events = p.feed(text: ": keep-alive\ndata: real\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "real")
    }

    func testCommentOnlyKeepAliveEmitsNothing() {
        var p = SSEParser()
        let events = p.feed(text: ": ping\n\n")
        XCTAssertTrue(events.isEmpty, "a comment-only block must not emit an event")
    }

    func testSplitChunksAcrossFeeds() {
        var p = SSEParser()
        var events = p.feed(text: "data: par")
        XCTAssertTrue(events.isEmpty, "no terminator yet → buffered")
        events = p.feed(text: "tial\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "partial")
    }

    func testCRLFLineEndings() {
        var p = SSEParser()
        let events = p.feed(text: "event: cards\r\ndata: x\r\n\r\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "cards")
        XCTAssertEqual(events[0].data, "x")
    }

    func testMultipleEventsInOneChunk() {
        var p = SSEParser()
        let events = p.feed(text: "data: a\n\ndata: b\n\n")
        XCTAssertEqual(events.map(\.data), ["a", "b"])
    }

    func testFieldWithoutSpaceAfterColon() {
        var p = SSEParser()
        let events = p.feed(text: "data:nospace\n\n")
        XCTAssertEqual(events[0].data, "nospace")
    }

    func testValueWithEmbeddedColons() {
        var p = SSEParser()
        let events = p.feed(text: "data: a:b:c\n\n")
        XCTAssertEqual(events[0].data, "a:b:c", "only the first colon splits field:value")
    }

    func testSplitChunkMidByteSequenceReassembles() {
        var p = SSEParser()
        // Split a frame at an arbitrary byte boundary across two feeds.
        let full = "event: decks\ndata: {\"id\":\"d1\"}\n\n"
        let bytes = Array(full.utf8)
        let mid = bytes.count / 2
        var events = p.feed(Data(bytes[0..<mid]))
        events += p.feed(Data(bytes[mid...]))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "decks")
        XCTAssertEqual(events[0].data, "{\"id\":\"d1\"}")
    }
}
