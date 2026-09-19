import Foundation

/// Moves a Claude chat from one account to another, so hitting a limit mid-conversation
/// doesn't mean losing the thread: pick the chat, pick another account, keep working.
///
/// What this can and can't do. A conversation belongs to exactly one organization, and
/// Claude exposes no cross-account import - there is no copy/fork/import endpoint, and a
/// share link only produces a read-only snapshot. So a transfer is a *seeded copy*: we
/// export the source chat and open a new one in the destination account primed with the
/// whole transcript. The two chats are independent from that point on; nothing you do in
/// one shows up in the other. Transferring back later is the same operation in reverse.
enum ChatTransfer {
    /// A chat as listed in an account's sidebar.
    struct ChatSummary: Equatable {
        var uuid: String
        var name: String
        var updatedAt: Date?

        /// Untitled chats come back with an empty name.
        var displayName: String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled chat" : trimmed
        }
    }

    struct TransferResult {
        var conversationUUID: String
        var chatName: String
        var messageCount: Int
        /// Set when the transcript was too long to send whole and only the tail was kept.
        var truncated: Bool

        var url: String { "https://claude.ai/chat/\(conversationUUID)" }
    }

    /// Claude models to try for the seeding message, in order. `nil` = the account
    /// default. A model the destination account can't use is rejected with a 403 before
    /// anything is generated, so falling through candidates is safe.
    private static let modelFallbacks: [String?] = [nil]

    /// Transcript size cap for the first attempt, then the retry. Long chats can exceed
    /// what a single message accepts, so we keep the most recent part and say so.
    private static let maxTranscriptCharacters = 250_000
    private static let retryTranscriptCharacters = 80_000

    // MARK: Reading an account's chats

    /// The account's most recently updated chats - the top one is whatever you were just
    /// working in, which is what a transfer almost always means.
    static func recentChats(for profile: LaunchProfile, allowKeychain: Bool, limit: Int = 6) throws -> [ChatSummary] {
        let context = try claudeContext(for: profile, allowKeychain: allowKeychain)
        return try recentChats(context: context, limit: limit)
    }

    static func recentChats(context: ClaudeContext, limit: Int) throws -> [ChatSummary] {
        let url = URL(string: "https://claude.ai/api/organizations/\(context.orgID)/chat_conversations?limit=\(limit)")!
        let response = try SimpleHTTP.get(url, headers: context.headers, timeout: 12)
        guard (200...299).contains(response.statusCode),
              let rows = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else {
            throw error("Couldn't list chats (HTTP \(response.statusCode)).")
        }
        return rows.compactMap { row in
            guard let uuid = row["uuid"] as? String else { return nil }
            return ChatSummary(
                uuid: uuid,
                name: (row["name"] as? String) ?? "",
                updatedAt: (row["updated_at"] as? String).flatMap(parseISODate))
        }
    }

    // MARK: Transferring

    /// Exports `chat` from `source` and opens a copy of it in `destination`, primed with
    /// the transcript so the new chat can carry on where the old one stopped.
    static func transfer(
        chat: ChatSummary,
        from source: LaunchProfile,
        to destination: LaunchProfile,
        allowKeychain: Bool
    ) throws -> TransferResult {
        let sourceContext = try claudeContext(for: source, allowKeychain: allowKeychain)
        let destinationContext = try claudeContext(for: destination, allowKeychain: allowKeychain)
        let export = try export(chat: chat, context: sourceContext)
        guard export.messageCount > 0 else {
            throw error("That chat has no messages to transfer yet.")
        }

        // Same name as the original, so the transferred chat is recognisable in the
        // destination account's sidebar instead of showing up as a new untitled thread.
        let conversationUUID = UUID().uuidString.lowercased()
        let createURL = URL(string: "https://claude.ai/api/organizations/\(destinationContext.orgID)/chat_conversations")!
        let created = try SimpleHTTP.send(
            createURL,
            method: "POST",
            jsonBody: ["uuid": conversationUUID, "name": export.name],
            headers: destinationContext.headers,
            timeout: 15)
        guard (200...299).contains(created.statusCode) else {
            throw error("Couldn't create the chat in \(accountLabel(destination)) (HTTP \(created.statusCode)). \(conciseError(created.data))")
        }

        // Send the transcript. If it comes back rejected for being too long, retry once
        // with just the recent part rather than failing the whole transfer.
        var transcript = export.transcript
        var truncated = export.truncated
        for attempt in 0..<2 {
            do {
                try seed(
                    transcript: transcript,
                    sourceLabel: accountLabel(source),
                    model: export.model,
                    conversationUUID: conversationUUID,
                    context: destinationContext)
                return TransferResult(
                    conversationUUID: conversationUUID,
                    chatName: export.name,
                    messageCount: export.messageCount,
                    truncated: truncated)
            } catch is TranscriptTooLong where attempt == 0 {
                let shortened = truncate(export.transcript, to: retryTranscriptCharacters)
                transcript = shortened.text
                truncated = true
            } catch let failure as ConversationNotPointed {
                // The transcript is in the chat; throwing away real work over a stray
                // pointer would be worse than handing back a chat that needs a nudge.
                throw failure
            } catch {
                // Nothing was sent, so don't leave an empty chat behind in the destination.
                deleteConversation(uuid: conversationUUID, context: destinationContext)
                throw error
            }
        }

        deleteConversation(uuid: conversationUUID, context: destinationContext)
        throw error("Couldn't send the transcript to \(accountLabel(destination)).")
    }

    // MARK: Export

    private struct Export {
        var name: String
        var transcript: String
        var messageCount: Int
        var truncated: Bool
        var model: String?
    }

    private static func export(chat: ChatSummary, context: ClaudeContext) throws -> Export {
        let url = URL(string: "https://claude.ai/api/organizations/\(context.orgID)/chat_conversations/\(chat.uuid)?tree=True&rendering_mode=raw")!
        let response = try SimpleHTTP.get(url, headers: context.headers, timeout: 30)
        guard (200...299).contains(response.statusCode),
              let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw error("Couldn't read that chat (HTTP \(response.statusCode)).")
        }

        let messages = orderedMessages(json)
        let name = ((json["name"] as? String) ?? chat.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let full = transcriptText(messages: messages)
        let capped = truncate(full, to: maxTranscriptCharacters)
        return Export(
            name: name.isEmpty ? chat.displayName : name,
            transcript: capped.text,
            messageCount: messages.count,
            truncated: capped.truncated,
            model: json["model"] as? String)
    }

    /// The conversation as the user actually sees it. A chat is stored as a tree (editing
    /// a message branches it), so walk back from the current leaf through the parent
    /// links to get the live thread, and only fall back to raw order if that fails.
    private static func orderedMessages(_ json: [String: Any]) -> [[String: Any]] {
        guard let messages = json["chat_messages"] as? [[String: Any]], !messages.isEmpty else { return [] }
        let byUUID = Dictionary(messages.compactMap { message -> (String, [String: Any])? in
            guard let uuid = message["uuid"] as? String else { return nil }
            return (uuid, message)
        }, uniquingKeysWith: { first, _ in first })

        if let leaf = json["current_leaf_message_uuid"] as? String, byUUID[leaf] != nil {
            var thread: [[String: Any]] = []
            var cursor: String? = leaf
            var guardrail = messages.count + 1
            while let uuid = cursor, let message = byUUID[uuid], guardrail > 0 {
                thread.append(message)
                cursor = message["parent_message_uuid"] as? String
                guardrail -= 1
            }
            if !thread.isEmpty {
                return thread.reversed()
            }
        }

        return messages.sorted { left, right in
            (left["index"] as? Int ?? 0) < (right["index"] as? Int ?? 0)
        }
    }

    private static func transcriptText(messages: [[String: Any]]) -> String {
        messages.compactMap { message -> String? in
            let isHuman = (message["sender"] as? String) == "human"
            var body = ((message["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            // Files and attachments stay behind in the source account, so name them
            // rather than silently dropping references the conversation depends on.
            let attachmentNames = (message["attachments"] as? [[String: Any]] ?? []).compactMap { $0["file_name"] as? String }
                + (message["files"] as? [[String: Any]] ?? []).compactMap { $0["file_name"] as? String }
            if !attachmentNames.isEmpty {
                let list = attachmentNames.joined(separator: ", ")
                body += body.isEmpty ? "[attached: \(list)]" : "\n\n[attached: \(list)]"
            }
            guard !body.isEmpty else { return nil }
            return "## \(isHuman ? "Human" : "Claude")\n\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// Keeps the tail of a long transcript - the end of a conversation is what you need
    /// to carry on from, and a whole-message cut is more readable than a mid-word one.
    private static func truncate(_ text: String, to limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        var kept = String(text.suffix(limit))
        if let firstTurn = kept.range(of: "\n## ") {
            kept = String(kept[firstTurn.lowerBound...])
        }
        return ("[Earlier messages were left out - this transcript starts partway through the conversation.]\n\(kept)", true)
    }

    // MARK: Seeding the destination chat

    private struct TranscriptTooLong: LocalizedError {
        var errorDescription: String? {
            "That conversation is too long to send as one message, even trimmed down."
        }
    }

    private struct ConversationNotPointed: LocalizedError {
        var url: String
        var reason: String
        var errorDescription: String? {
            "The transcript was sent, but Claude wouldn't point the chat at it (\(reason)), so it may open blank. It's at \(url)"
        }
    }

    /// Sends the transcript as an attachment plus a short instruction, so the new chat
    /// opens with a readable prompt and a file rather than a wall of pasted text.
    private static func seed(
        transcript: String,
        sourceLabel: String,
        model: String?,
        conversationUUID: String,
        context: ClaudeContext
    ) throws {
        let url = URL(string: "https://claude.ai/api/organizations/\(context.orgID)/chat_conversations/\(conversationUUID)/completion")!
        var headers = context.headers
        headers["Accept"] = "text/event-stream"

        let attachment: [String: Any] = [
            "file_name": "conversation-so-far.md",
            "file_type": "text/markdown",
            "file_size": transcript.utf8.count,
            "extracted_content": transcript,
        ]
        let prompt = """
        This chat is being continued from another Claude account (\(sourceLabel)), which ran out of usage. \
        The attached transcript is the conversation so far: “Human” is me, “Claude” is you. \
        Read it, then pick up exactly where it left off - same task, same context, same decisions already made. \
        Reply with one short line confirming where we are, then wait for my next message.
        """

        // The source chat's model first, then the account default: a model the
        // destination isn't entitled to is rejected before anything is generated.
        var candidates: [String?] = modelFallbacks
        if let model, !model.isEmpty {
            candidates = [model] + candidates
        }

        var lastStatus = 0
        var lastMessage = ""
        for candidate in candidates {
            var body: [String: Any] = [
                "prompt": prompt,
                "parent_message_uuid": "00000000-0000-4000-8000-000000000000",
                "timezone": TimeZone.current.identifier,
                "attachments": [attachment],
                "files": [],
                "rendering_mode": "messages",
            ]
            if let candidate { body["model"] = candidate }

            let response = try SimpleHTTP.send(url, method: "POST", jsonBody: body, headers: headers, timeout: 120)
            if (200...299).contains(response.statusCode) {
                try pointConversationAtLastMessage(conversationUUID: conversationUUID, context: context)
                return
            }

            lastStatus = response.statusCode
            lastMessage = conciseError(response.data)
            let lowered = lastMessage.lowercased()
            if lowered.contains("too long") || lowered.contains("maximum") || lowered.contains("length") {
                throw TranscriptTooLong()
            }
            // Only a model-availability problem is worth another attempt.
            if !lowered.contains("model") { break }
        }

        if lastStatus == 429 {
            throw error("The destination account is out of usage too (HTTP 429). \(lastMessage)")
        }
        throw error("Couldn't send the transcript (HTTP \(lastStatus)). \(lastMessage)")
    }

    /// Claude renders a chat by walking back from its "current leaf" pointer, and a
    /// message posted through the API doesn't move that pointer on its own. Without this
    /// the transferred chat opens completely blank - the messages are there, but the app
    /// has no thread to follow to them - so this is what makes a transfer visible at all.
    private static func pointConversationAtLastMessage(conversationUUID: String, context: ClaudeContext) throws {
        let conversationURL = "https://claude.ai/api/organizations/\(context.orgID)/chat_conversations/\(conversationUUID)"
        var lastError = ""

        // Two goes: the reply is written as the stream ends, so an immediate read can
        // land just before the assistant message exists.
        for attempt in 0..<2 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 1.5)
            }
            guard let response = try? SimpleHTTP.get(
                    URL(string: "\(conversationURL)?tree=True&rendering_mode=raw")!,
                    headers: context.headers,
                    timeout: 20),
                  let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let messages = json["chat_messages"] as? [[String: Any]],
                  let last = messages.max(by: { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }),
                  let leaf = last["uuid"] as? String else {
                lastError = "the new chat couldn't be read back"
                continue
            }

            let update = try? SimpleHTTP.send(
                URL(string: "\(conversationURL)/current_leaf_message_uuid")!,
                method: "PUT",
                jsonBody: ["current_leaf_message_uuid": leaf],
                headers: context.headers,
                timeout: 15)
            if let update, (200...299).contains(update.statusCode) { return }
            lastError = "HTTP \(update?.statusCode ?? 0)"
        }

        throw ConversationNotPointed(url: "https://claude.ai/chat/\(conversationUUID)", reason: lastError)
    }

    private static func deleteConversation(uuid: String, context: ClaudeContext) {
        let url = URL(string: "https://claude.ai/api/organizations/\(context.orgID)/chat_conversations/\(uuid)")!
        _ = try? SimpleHTTP.send(url, method: "DELETE", headers: context.headers, timeout: 8)
    }

    // MARK: Shared helpers

    struct ClaudeContext {
        var orgID: String
        var headers: [String: String]
    }

    static func claudeContext(for profile: LaunchProfile, allowKeychain: Bool) throws -> ClaudeContext {
        let cookieHeader = try UsageRefresher.claudeCookieHeader(for: profile, allowKeychain: allowKeychain)
        let orgID = try UsageRefresher.claudeOrganizationID(cookieHeader: cookieHeader)
        return ClaudeContext(orgID: orgID, headers: UsageRefresher.claudeHeaders(cookieHeader: cookieHeader))
    }

    static func accountLabel(_ profile: LaunchProfile) -> String {
        profile.accountEmail ?? profile.accountName ?? profile.label
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LLMUsageBar.ChatTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func conciseError(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["detail"] as? String {
                return message
            }
        }
        return (String(data: data.prefix(160), encoding: .utf8) ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
