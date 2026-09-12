import Foundation

@main struct ProtocolTests {
    static func main() throws {
        for json in [
            #"{"version":1,"id":"r1","operation":"delete","workload_id":"../../other"}"#,
            #"{"version":1,"id":"r1","operation":"inspect","workload_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","command":"rm"}"#
        ] {
            do { _ = try Request.decode(Data(json.utf8)); fatalError("accepted unsafe request") }
            catch { }
        }
        let request = try Request.decode(Data(#"{"version":1,"id":"r1","operation":"inspect","workload_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}"#.utf8))
        precondition(request.operation == "inspect")
        print("protocol paths and unknown fields: PASS")
    }
}
