import Foundation
import Testing
@testable import Blitz

@Test func testSequencedPipeBufferReassemblesOutOfOrderChunks() {
    var buffer = SequencedPipeBuffer()

    let delayed = buffer.append(Data("\"result\":{\"statusCode\":200}}\n".utf8), sequence: 1)
    #expect(delayed.isEmpty)

    let lines = buffer.append(Data("{\"id\":\"ascd-39\",".utf8), sequence: 0)
    #expect(lines.count == 1)
    #expect(String(data: lines[0], encoding: .utf8) == "{\"id\":\"ascd-39\",\"result\":{\"statusCode\":200}}")
}

@Test func testSequencedPipeBufferFlushesTrailingChunkAtEOF() {
    var buffer = SequencedPipeBuffer()

    let partial = buffer.append(Data("partial stderr".utf8), sequence: 0)
    #expect(partial.isEmpty)

    let flushed = buffer.append(Data(), sequence: 1)
    #expect(flushed.count == 1)
    #expect(String(data: flushed[0], encoding: .utf8) == "partial stderr")
}
