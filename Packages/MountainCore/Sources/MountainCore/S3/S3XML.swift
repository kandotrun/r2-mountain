import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

struct S3XMLNode {
  let name: String
  var text = ""
  var children: [S3XMLNode] = []

  func child(_ name: String) -> S3XMLNode? { children.first { $0.name == name } }
  func value(_ name: String) -> String? {
    child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class S3XMLDelegate: NSObject, XMLParserDelegate {
  var stack: [S3XMLNode] = []
  var root: S3XMLNode?
  var failed = false

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    guard stack.count < 32 else {
      failed = true
      parser.abortParsing()
      return
    }
    stack.append(S3XMLNode(name: elementName))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !stack.isEmpty else { return }
    stack[stack.count - 1].text += string
  }

  func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
    guard !stack.isEmpty, let text = String(data: cdataBlock, encoding: .utf8) else { return }
    stack[stack.count - 1].text += text
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard let node = stack.popLast(), node.name == elementName else {
      failed = true
      parser.abortParsing()
      return
    }
    if stack.isEmpty {
      guard root == nil else {
        failed = true
        parser.abortParsing()
        return
      }
      root = node
    } else {
      stack[stack.count - 1].children.append(node)
    }
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) { failed = true }
}

enum S3XML {
  static func parse(_ data: Data, status: Int) throws -> S3XMLNode {
    guard data.count <= 8 * 1_024 * 1_024 else {
      throw S3Failure(status: status, code: "OversizedXMLResponse")
    }
    guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
      throw S3Failure(status: status, code: "MalformedXMLResponse")
    }
    guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
      !text.localizedCaseInsensitiveContains("<!ENTITY")
    else {
      throw S3Failure(status: status, code: "UnsafeXMLResponse")
    }
    let delegate = S3XMLDelegate()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), !delegate.failed, delegate.stack.isEmpty, let root = delegate.root else {
      throw S3Failure(status: status, code: "MalformedXMLResponse")
    }
    return root
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}
