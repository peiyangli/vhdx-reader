import Darwin
import Flutter
import XCTest
@testable import Runner

final class RunnerTests: XCTestCase {
  func testSavedCredentialSurvivesContextRecreation() async throws {
    try await Task.detached(priority: .userInitiated) {
      try Self.verifySavedCredentialSurvivesContextRecreation()
    }.value
  }

  private static func verifySavedCredentialSurvivesContextRecreation() throws {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("vhdx-validation")
    let image = root.appendingPathComponent("bitlockervhdx.vhdx").path
    let password = root.appendingPathComponent("password.txt").path
    guard FileManager.default.fileExists(atPath: image), FileManager.default.fileExists(atPath: password) else {
      throw XCTSkip("Private vault fixtures are not installed in this test host")
    }
    let directory = try XCTUnwrap(Bundle.main.privateFrameworksPath)
    let library = try XCTUnwrap(dlopen(directory + "/vhdx_app.framework/vhdx_app", RTLD_NOW | RTLD_LOCAL))
    // Match Dart's process-lifetime library ownership: the shared Rust worker
    // remains alive after individual reader contexts have been disposed.
    typealias Create = @convention(c) () -> UInt64
    typealias Request = @convention(c) (UInt64, UnsafePointer<UInt8>?, UInt) -> UnsafeMutablePointer<CChar>?
    typealias Release = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    let create = unsafeBitCast(try XCTUnwrap(dlsym(library, "vhdx_context_create")), to: Create.self)
    let request = unsafeBitCast(try XCTUnwrap(dlsym(library, "vhdx_request")), to: Request.self)
    let release = unsafeBitCast(try XCTUnwrap(dlsym(library, "vhdx_response_free")), to: Release.self)
    var context = create()
    var session: UInt64 = 0
    func call(_ parameters: [String: Any]) throws -> [String: Any] {
      var params = parameters
      let operation = parameters["op"] as? String ?? ""
      if !["open", "dispose", "vault_remove", "vault_list", "vault_clear"].contains(operation) { params["session"] = session }
      let input = try JSONSerialization.data(withJSONObject: params)
      let response = try XCTUnwrap(input.withUnsafeBytes { buffer in
        request(context, buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count))
      })
      defer { release(response) }
      let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes: response, count: strlen(response))) as? [String: Any])
      if let generation = value["session"] as? NSNumber { session = generation.uint64Value }
      guard value["ok"] as? Bool == true else {
        let code = (value["error"] as? [String: Any])?["code"] as? String ?? "unknown"
        throw NSError(domain: "VaultTest", code: 1, userInfo: [NSLocalizedDescriptionKey: code])
      }
      return value["data"] as? [String: Any] ?? [:]
    }
    defer { _ = try? call(["op": "dispose"]) }
    _ = try call(["op": "open", "path": image, "native_directory": directory])
    let status = try call(["op": "vault_status", "partition": 1])
    XCTAssertEqual(status["available"] as? Bool, true)
    if status["saved"] as? Bool == true { throw XCTSkip("Keep the user's existing saved fixture credential") }
    let id = try XCTUnwrap(status["id"] as? String)
    defer { _ = try? call(["op": "vault_remove", "id": id]) }
    let unlocked = try call(["op": "unlock", "partition": 1, "mode": "password", "credential_file": password, "remember": true, "label": "iPhone Keychain regression"])
    XCTAssertEqual(unlocked["remembered"] as? Bool, true)
    _ = try call(["op": "dispose"])
    context = create(); session = 0
    _ = try call(["op": "open", "path": image, "native_directory": directory])
    _ = try call(["op": "unlock_saved", "partition": 1])
    let read = try call(["op": "read", "path": "/hello.txt", "offset": 0, "length": 16])
    XCTAssertEqual(read["size"] as? Int, 5)
    _ = try call(["op": "vault_remove", "id": id])
    XCTAssertEqual(try call(["op": "vault_status", "partition": 1])["saved"] as? Bool, false)
  }

  private func request(_ storage: DocumentStorage, _ method: String,
                       _ args: [String: Any], _ check: @escaping (Any?) -> Void) {
    let done = expectation(description: method)
    storage.handle(FlutterMethodCall(methodName: method, arguments: args)) { value in
      check(value)
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
  }

  func testReadOnlyLeasesRemainIndependent() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("first.vhdx")
    let second = folder.appendingPathComponent("second.vhdx")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let storage = DocumentStorage()
    let docs = storage.remember([first, second])
    var descriptors: [(Int32, Int)] = []
    for doc in docs {
      request(storage, "openDescriptor", ["uri": doc["uri"]!, "write": false]) { value in
        guard let map = value as? [String: Int], let fd = map["fd"], let handle = map["handle"] else {
          XCTFail("Expected a read descriptor"); return
        }
        XCTAssertEqual(fcntl(Int32(fd), F_GETFL) & O_ACCMODE, O_RDONLY)
        descriptors.append((Int32(fd), handle))
      }
    }
    XCTAssertEqual(descriptors.count, 2)
    guard descriptors.count == 2 else { return }
    request(storage, "closeDescriptor", ["handle": descriptors[0].1]) { _ in }
    XCTAssertEqual(fcntl(descriptors[0].0, F_GETFD), -1)
    var data = [UInt8](repeating: 0, count: 6)
    XCTAssertEqual(read(descriptors[1].0, &data, data.count), 6)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "second")
    request(storage, "openDescriptor", ["uri": docs[1]["uri"]!, "write": true]) { value in
      XCTAssertTrue(value is FlutterError)
    }
    request(storage, "closeDescriptor", ["handle": descriptors[1].1]) { _ in }
    XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
  }

  func testExportNeverOverwritesAndCleansOnlyCreatedFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let existing = folder.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: existing)
    let storage = DocumentStorage()
    let keep = storage.remember([folder], exportName: "keep.txt")[0]["uri"]!
    request(storage, "openDescriptor", ["uri": keep, "write": true]) { XCTAssertTrue($0 is FlutterError) }
    request(storage, "removeExport", ["uri": keep]) { XCTAssertNil($0) }
    XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    let created = storage.remember([folder], exportName: "partial.txt")[0]["uri"]!
    var handle: Int?
    request(storage, "openDescriptor", ["uri": created, "write": true]) { value in
      handle = (value as? [String: Int])?["handle"]
    }
    XCTAssertNotNil(handle)
    if let handle = handle { request(storage, "closeDescriptor", ["handle": handle]) { _ in } }
    request(storage, "removeExport", ["uri": created]) { XCTAssertNil($0) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("partial.txt").path))
  }
}
