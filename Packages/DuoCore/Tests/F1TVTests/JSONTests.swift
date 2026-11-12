import Foundation
import Testing
@testable import F1TV

@Suite struct JSONValueTests {
    static let v = try! JSONValue.parse(Data(#"{"a":"x","n":5,"s":"7","t":"true","f":false,"z":null,"arr":[1,"b"],"d":1.5}"#.utf8))

    @Test func lenientAccessors() {
        let v = Self.v
        #expect(v["a"].string == "x")
        #expect(v["n"].string == "5")
        #expect(v["d"].string == "1.5")
        #expect(v["z"].string == "")
        #expect(v["missing"].string == "")
        #expect(v["arr"].string == "")
        #expect(v["n"].int == 5)
        #expect(v["s"].int == 7)
        #expect(v["a"].int == nil)
        #expect(v["t"].bool == true)
        #expect(v["f"].bool == false)
        #expect(v["a"].bool == nil)
        #expect(v["arr"].array.count == 2)
        #expect(v["a"].array.isEmpty)
        #expect(v["arr"][1].string == "b")
        #expect(v["arr"][9] == .null)
        #expect(v["a"]["b"] == .null)
        #expect(v["a"][0] == .null)
    }
}
