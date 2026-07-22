import Testing

@testable import ThermalForgeCore

@Suite("Daemon Codec")
struct DaemonCodecTests {
    @Test("Request round-trip")
    func requestRoundTrip() throws {
        let original = DaemonRequest(requestID: "abc", command: "set", rpm: 4_200)
        let encoded = try DaemonCodec.encodeRequest(original)
        let decoded = try DaemonCodec.decodeRequest(encoded)
        #expect(decoded == original)
        #expect(String(decoding: encoded, as: UTF8.self) == "{\"command\":\"set\",\"requestID\":\"abc\",\"rpm\":4200,\"version\":1}")
    }

    @Test("Response round-trip with error")
    func responseRoundTrip() throws {
        let original = DaemonResponse(
            requestID: "abc",
            ok: false,
            message: nil,
            status: nil,
            error: DaemonErrorPayload(code: "validation_error", message: "missing rule")
        )
        let encoded = try DaemonCodec.encodeResponse(original)
        let decoded = try DaemonCodec.decodeResponse(encoded)
        #expect(decoded == original)
    }
}
