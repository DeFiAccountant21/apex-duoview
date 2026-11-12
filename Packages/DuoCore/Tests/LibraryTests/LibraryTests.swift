import Testing
@testable import Library

@Test func libraryNamespaceExists() {
    #expect(Library.self == Library.self)
}
