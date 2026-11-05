import Foundation
import Testing

@testable import MountainCore

@Suite("Signature Version 4")
struct SigV4SignerTests {
  @Test("AWS published IAM ListUsers signature")
  func publishedAWSVector() throws {
    // Public AWS example credentials, never usable credentials.
    // https://aws.amazon.com/blogs/security/how-to-use-the-rest-api-to-encrypt-s3-objects-by-using-aws-kms/
    let result = SigV4Signer.sign(
      method: "GET", canonicalURI: "/",
      canonicalQuery: "Action=ListUsers&Version=2010-05-08",
      headers: [
        "content-type": "application/x-www-form-urlencoded; charset=utf-8",
        "host": "iam.amazonaws.com", "x-amz-date": "20150830T123600Z",
      ],
      payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      credentials: S3Credentials(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
      ), region: "us-east-1", service: "iam"
    )
    #expect(result.signature == "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    #expect(result.signedHeaders == "content-type;host;x-amz-date")
  }

  @Test("Header whitespace is canonicalized and metadata is signed")
  func headerCanonicalization() {
    let headers = [
      "Host": "example.test", "X-Amz-Date": "20261104T100000Z", "Content-MD5": "  abc= \t",
      "X-Amz-Meta-S3-Mountain-Job-ID": "job-1",
    ]
    let result = SigV4Signer.sign(
      method: "PUT", canonicalURI: "/drive/a", canonicalQuery: "",
      headers: headers, payloadHash: "UNSIGNED-PAYLOAD",
      credentials: S3Credentials(accessKeyID: "test", secretAccessKey: "test")
    )
    #expect(result.canonicalRequest.contains("content-md5:abc=\n"))
    #expect(result.signedHeaders.contains("x-amz-meta-s3-mountain-job-id"))
    #expect(result.canonicalRequest.hasSuffix("UNSIGNED-PAYLOAD"))
  }
}
