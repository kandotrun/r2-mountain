import Foundation
import MountainCore

/// Explicitly invoked developer probe. Secrets are read from a private file, never printed.
@main
struct MountainVerify {
  static func main() async {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      guard args.count == 4 else {
        throw ProbeError.usage
      }
      let setupURL = URL(fileURLWithPath: args[0])
      let sourceURL = URL(fileURLWithPath: args[1])
      let journalURL = URL(fileURLWithPath: args[2], isDirectory: true)
      let prefix = args[3]
      guard prefix.hasPrefix("s3-mountain-tests/"), prefix.count > 40 else {
        throw ProbeError.usage
      }
      let setup = try JSONDecoder().decode(Setup.self, from: Data(contentsOf: setupURL))
      let configuration = R2Configuration(
        accountID: setup.accountID, bucket: setup.bucket,
        jurisdiction: R2Configuration.Jurisdiction(rawValue: setup.jurisdiction) ?? .standard
      )
      try configuration.validate()
      let client = S3Client(
        configuration: configuration,
        credentials: S3Credentials(
          accessKeyID: setup.accessKeyID, secretAccessKey: setup.secretAccessKey)
      )
      try await client.testConnection()
      let engine = UploadEngine(
        configuration: configuration, client: client, journalDirectory: journalURL)
      try await engine.restore()
      if await engine.currentJobs().isEmpty {
        try await engine.enqueue(urls: [sourceURL], prefix: prefix)
      }
      let snapshots = await engine.snapshots()
      for await jobs in snapshots {
        guard let job = jobs.first else { continue }
        let event: [String: Any] = [
          "state": job.state.rawValue, "completedBytes": job.completedBytes,
          "size": job.size, "key": job.key,
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
        if job.state == .completed {
          await engine.prepareForTermination()
          return
        }
        if [.failed, .needsCredentials, .cancelled, .waitingForNetwork, .reconciling].contains(
          job.state)
        {
          await engine.prepareForTermination()
          throw ProbeError.uploadFailed
        }
      }
    } catch {
      FileHandle.standardError.write(
        Data("Verification did not complete. Credentials are not displayed.\n".utf8))
      exit(1)
    }
  }

  struct Setup: Decodable {
    let accountID: String
    let bucket: String
    let jurisdiction: String
    let accessKeyID: String
    let secretAccessKey: String
  }

  enum ProbeError: Error { case usage, uploadFailed }
}
