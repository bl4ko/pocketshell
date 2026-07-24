import Testing

@testable import TerminalUI

@Test func nullCellsBecomeSpaces() {
    #expect(SelectionText.join(rows: ["export\u{0}TART_HOME=/x"], startCol: 0, endCol: 20) == "export TART_HOME=/x")
}

@Test func slicesFirstAndLastRowByColumn() {
    #expect(SelectionText.join(rows: ["hello world"], startCol: 6, endCol: 10) == "world")
    #expect(SelectionText.join(rows: ["abcdef", "ghijkl"], startCol: 2, endCol: 3) == "cdef\nghij")
}

@Test func startColBeyondRowLengthYieldsEmptyRow() {
    #expect(SelectionText.join(rows: ["ab", "cdef"], startCol: 5, endCol: 3) == "\ncdef")
}

@Test func endColBeyondRowLengthClamps() {
    #expect(SelectionText.join(rows: ["abc"], startCol: 0, endCol: 99) == "abc")
}
