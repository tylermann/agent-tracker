import Foundation

public enum EventMapper {
  public static func map(
    harness: Harness,
    eventName: String,
    payloadData: Data,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    now: Date = Date()
  ) throws -> AgentEvent? {
    let payload = try decodeObject(payloadData)
    let normalized = eventName.replacingOccurrences(
      of: "[^a-zA-Z]",
      with: "",
      options: .regularExpression
    ).lowercased()

    let kind: AgentEventKind?
    switch normalized {
    case "sessionstart":
      kind = .sessionStarted
    case "userpromptsubmit", "beforesubmitprompt":
      kind = .promptSubmitted
    case "permissionrequest":
      // Codex emits this hook before its optional automatic reviewer decides whether the command
      // can proceed. It is only an in-progress review in that mode, not an actionable prompt.
      kind = harness == .codex && environment["AGENT_TRACKER_CODEX_AUTO_REVIEW"] == "1"
        ? .activity : .attentionRequired
    case "notification":
      let notificationType = string(
        in: payload,
        keys: ["notification_type", "notificationType"]
      )?.lowercased()
      if notificationType == nil
        || notificationType == "permission_prompt"
        || notificationType == "idle_prompt"
        || notificationType == "elicitation_dialog"
      {
        kind = .attentionRequired
      } else {
        return nil
      }
    case "pretooluse":
      let tool = string(in: payload, keys: ["tool_name", "toolName"])?.lowercased() ?? ""
      if tool.contains("askquestion")
        || tool.contains("requestuserinput")
        || tool.contains("request_user_input")
        || (harness == .cursor && cursorToolRequiresApproval(tool))
      {
        kind = .attentionRequired
      } else {
        kind = .activity
      }
    case "beforeshellexecution", "beforemcpexecution":
      kind = harness == .cursor ? .attentionRequired : .activity
    case "posttooluse", "posttoolusefailure", "aftershellexecution", "aftermcpexecution",
      "afterfileedit":
      kind = .activity
    case "stop":
      kind = .turnStopped
    case "sessionend":
      kind = .sessionEnded
    default:
      kind = .activity
    }

    guard let kind else { return nil }
    let sessionID = string(
      in: payload,
      keys: ["session_id", "sessionId", "conversation_id", "conversationId", "chat_id", "chatId"]
    )
    let runID =
      environment["AGENT_TRACKER_RUN_ID"]
      // Cursor CLI also executes Claude Code-compatible hooks. Keep the fallback identity
      // harness-neutral so both hook formats resolve to the same underlying session.
      ?? sessionID.map { "orphan-\($0)" }
      ?? "orphan-\(harness.rawValue)-\(UUID().uuidString)"
    let rawPrompt = string(in: payload, keys: ["prompt", "user_prompt", "userPrompt"])
    let detail = string(
      in: payload,
      keys: ["notification_type", "notificationType", "message", "tool_name", "toolName"]
    )

    return AgentEvent(
      occurredAt: now,
      runID: runID,
      harness: harness,
      kind: kind,
      harnessSessionID: sessionID,
      ghosttyTerminalID: environment["AGENT_TRACKER_TERMINAL_ID"],
      processID: int32(environment["AGENT_TRACKER_CHILD_PID"]),
      cwd: string(
        in: payload,
        keys: ["cwd", "workspace_root", "workspaceRoot", "workspace_roots", "workspaceRoots"]
      )
        ?? environment["PWD"],
      promptPreview: rawPrompt.map { promptPreview($0) },
      detail: detail
    )
  }

  public static func promptPreview(_ text: String, limit: Int = 120) -> String {
    let normalized =
      text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard normalized.count > limit else { return normalized }
    let end = normalized.index(normalized.startIndex, offsetBy: max(1, limit - 1))
    return String(normalized[..<end]) + "…"
  }

  private static func decodeObject(_ data: Data) throws -> Any {
    guard !data.isEmpty else { return [String: Any]() }
    return try JSONSerialization.jsonObject(with: data)
  }

  private static func string(in value: Any, keys: [String]) -> String? {
    if let dictionary = value as? [String: Any] {
      for key in keys {
        if let string = dictionary[key] as? String, !string.isEmpty {
          return string
        }
        if let strings = dictionary[key] as? [String],
          let string = strings.first(where: { !$0.isEmpty })
        {
          return string
        }
      }
      for nested in dictionary.values {
        if let match = string(in: nested, keys: keys) { return match }
      }
    } else if let array = value as? [Any] {
      for nested in array {
        if let match = string(in: nested, keys: keys) { return match }
      }
    }
    return nil
  }

  private static func int32(_ value: String?) -> Int32? {
    guard let value, let number = Int32(value) else { return nil }
    return number
  }

  private static func cursorToolRequiresApproval(_ tool: String) -> Bool {
    let normalized = tool.replacingOccurrences(
      of: "[^a-zA-Z]",
      with: "",
      options: .regularExpression
    ).lowercased()
    return normalized == "websearch" || normalized == "webfetch"
  }
}
