import CryptoKit
import Foundation

struct SigV4Signature: Sendable {
  let canonicalRequest: String
  let signedHeaders: String
  let signature: String
  let authorization: String
}

enum SigV4Signer {
  static func sign(
    method: String,
    canonicalURI: String,
    canonicalQuery: String,
    headers: [String: String],
    payloadHash: String,
    credentials: S3Credentials,
    region: String = "auto",
    service: String = "s3"
  ) -> SigV4Signature {
    var normalized: [String: String] = [:]
    for (name, value) in headers where name.lowercased() != "authorization" {
      let cleanValue = value.split(whereSeparator: {
        $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
      }).joined(separator: " ")
      normalized[name.lowercased()] = cleanValue
    }
    let names = normalized.keys.sorted()
    let signedHeaders = names.joined(separator: ";")
    let canonicalHeaders = names.map { "\($0):\(normalized[$0]!)\n" }.joined()
    let canonicalRequest = [
      method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash,
    ].joined(separator: "\n")
    let timestamp = normalized["x-amz-date"] ?? ""
    let day = String(timestamp.prefix(8))
    let scope = "\(day)/\(region)/\(service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256", timestamp, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
    ].joined(separator: "\n")
    let dateKey = hmac(key: Data(("AWS4" + credentials.secretAccessKey).utf8), message: day)
    let regionKey = hmac(key: dateKey, message: region)
    let serviceKey = hmac(key: regionKey, message: service)
    let signingKey = hmac(key: serviceKey, message: "aws4_request")
    let signature = hex(hmac(key: signingKey, message: stringToSign))
    return SigV4Signature(
      canonicalRequest: canonicalRequest,
      signedHeaders: signedHeaders,
      signature: signature,
      authorization:
        "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    )
  }

  static func uriEncode(_ value: String, preserveSlash: Bool = false) -> String {
    value.utf8.map { byte in
      switch byte {
      case 65...90, 97...122, 48...57, 45, 46, 95, 126:
        return String(UnicodeScalar(byte))
      case 47 where preserveSlash:
        return "/"
      default:
        return String(format: "%%%02X", byte)
      }
    }.joined()
  }

  private static func hmac(key: Data, message: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
  }

  private static func hex(_ data: some Sequence<UInt8>) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }
}
