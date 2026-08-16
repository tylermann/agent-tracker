import Foundation

/// Model identity shared by capture, persistence, and presentation.
public enum ModelIdentity {
  /// Extracts the model selected on a provider command line. All three supported CLIs accept
  /// `--model`; Claude and Codex also commonly use `-m`. Codex's generic config override is
  /// included because model aliases sometimes expand to `codex -c model=...`.
  public static func commandLineModel(arguments: [String]) -> String? {
    var model: String?
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      if argument == "--model" || argument == "-m" {
        let valueIndex = arguments.index(after: index)
        if valueIndex < arguments.endIndex, !arguments[valueIndex].hasPrefix("-") {
          model = usable(arguments[valueIndex])
          index = valueIndex
        }
      }
      for prefix in ["--model=", "-m="] where argument.hasPrefix(prefix) {
        if let value = usable(String(argument.dropFirst(prefix.count))) { model = value }
      }
      if argument == "--config" || argument == "-c" {
        let valueIndex = arguments.index(after: index)
        if valueIndex < arguments.endIndex,
          let value = configModel(arguments[valueIndex])
        {
          model = value
          index = valueIndex
        }
      }
      if argument.hasPrefix("--config="),
        let value = configModel(String(argument.dropFirst("--config=".count)))
      {
        model = value
      }
      index = arguments.index(after: index)
    }
    return model
  }

  /// Turns provider model IDs into compact names that fit the row header. Provider-specific
  /// aliases deliberately omit Anthropic's release/version suffixes: "Fable" is the useful choice
  /// to scan for, while "claude-fable-5-20260801" is implementation detail.
  public static func displayName(for rawModel: String?) -> String? {
    guard let rawModel = usable(rawModel) else { return nil }
    let normalized = rawModel.lowercased().replacingOccurrences(of: "_", with: "-")

    for family in ["fable", "mythos", "opus", "sonnet", "haiku"]
    where containsToken(family, in: normalized) {
      return family.capitalized
    }

    for family in ["sol", "terra", "luna"] where containsToken(family, in: normalized) {
      return labeled(family.capitalized, version: version(in: normalized))
    }

    let knownFamilies: [(needle: String, label: String)] = [
      ("grok", "Grok"),
      ("composer", "Composer"),
      ("gemini", "Gemini"),
      ("gpt", "GPT"),
    ]
    for family in knownFamilies where containsToken(family.needle, in: normalized) {
      return labeled(family.label, version: version(in: normalized))
    }

    // A payload may already contain a human-readable display name. Preserve its spacing and
    // capitalization instead of trying to improve it.
    if rawModel.contains(" ") { return rawModel }
    return rawModel.split(whereSeparator: { $0 == "-" || $0 == "_" })
      .map { $0.capitalized }
      .joined(separator: " ")
  }

  private static func configModel(_ argument: String) -> String? {
    let pieces = argument.split(separator: "=", maxSplits: 1).map(String.init)
    guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces) == "model" else {
      return nil
    }
    return usable(pieces[1])
  }

  private static func usable(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(
      in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("default") != .orderedSame else {
      return nil
    }
    return trimmed
  }

  private static func containsToken(_ token: String, in value: String) -> Bool {
    value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == token }
  }

  private static func version(in value: String) -> String? {
    value.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "/" || $0 == " " })
      .map(String.init)
      .first { component in
        component.first?.isNumber == true
          && component.allSatisfy { $0.isNumber || $0 == "." }
      }
  }

  private static func labeled(_ family: String, version: String?) -> String {
    version.map { "\(family) \($0)" } ?? family
  }
}
