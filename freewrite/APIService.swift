// APIService.swift
//  freewrite
//
//  API Service with conversation memory and cost control
//

import Foundation

/// Manages API interactions with conversation memory and cost control
class APIService: ObservableObject {
    
    // MARK: - Constants
    private enum Constants {
        static let maxConversationHistory = 10 // Limit to last 10 messages to control API costs
        static let maxTokensPerRequest = 2000
        static let conversationCacheKey = "chat_conversations"
    }
    
    // MARK: - Models
    struct ConversationContext: Codable {
        let messages: [ChatMessage]
        let journalEntry: String
        let provider: AIProvider
        let createdAt: Date
        
        /// Gets recent messages within token limit for API context
        func getRecentMessages(limit: Int = Constants.maxConversationHistory) -> [ChatMessage] {
            return Array(messages.suffix(limit))
        }
    }
    
    // MARK: - Properties
    @Published var isLoading = false
    private let urlSession: URLSession
    private let conversationCache: ConversationCache
    
    // MARK: - Initialization
    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.conversationCache = ConversationCache()
    }
    
    // MARK: - Public Methods
    
    /// Sends a message with conversation context and persists the conversation
    func sendMessage(
        _ message: String,
        provider: AIProvider,
        journalEntry: String,
        conversationId: UUID,
        existingMessages: [ChatMessage] = []
    ) async throws -> String {
        
        isLoading = true
        defer { isLoading = false }
        
        // Get API key
        guard let apiKey = getAPIKey(for: provider) else {
            throw APIError.authenticationError
        }
        
        // Load existing conversation context
        var context = conversationCache.getConversation(id: conversationId) ?? 
                     ConversationContext(
                        messages: existingMessages,
                        journalEntry: journalEntry,
                        provider: provider,
                        createdAt: Date()
                     )
        
        // Create contextual prompt with conversation history
        let contextualPrompt = createContextualPrompt(
            userMessage: message,
            journalEntry: journalEntry,
            conversationHistory: context.getRecentMessages()
        )
        
        // Make API call
        let response: String
        switch provider {
        case .chatGPT:
            response = try await callOpenAIAPI(message: contextualPrompt, apiKey: apiKey)
        case .claude:
            response = try await callAnthropicAPI(message: contextualPrompt, apiKey: apiKey)
        }
        
        // Update conversation context with new messages (using weak references pattern)
        let userMessage = ChatMessage(content: message, isUser: true, timestamp: Date(), provider: provider)
        let aiMessage = ChatMessage(content: response, isUser: false, timestamp: Date(), provider: provider)
        
        context = ConversationContext(
            messages: context.messages + [userMessage, aiMessage],
            journalEntry: journalEntry,
            provider: provider,
            createdAt: context.createdAt
        )
        
        // Persist updated conversation (using lazy evaluation for performance)
        conversationCache.saveConversation(context, for: conversationId)
        
        return response
    }
    
    /// Clears conversation memory for a specific conversation
    func clearConversation(id: UUID) {
        conversationCache.removeConversation(id: id)
    }
    
    /// Gets conversation history for display
    func getConversationHistory(id: UUID) -> [ChatMessage] {
        return conversationCache.getConversation(id: id)?.messages ?? []
    }
}

// MARK: - Private Methods
private extension APIService {
    
    func getAPIKey(for provider: AIProvider) -> String? {
        guard let key = UserDefaults.standard.string(forKey: provider.keyName),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return key
    }
    
    /// Creates contextual prompt with conversation memory
    func createContextualPrompt(
        userMessage: String,
        journalEntry: String,
        conversationHistory: [ChatMessage]
    ) -> String {
        
        var prompt = """
        You are an AI assistant helping someone reflect on their journal entry. 
        Be conversational, insightful, and helpful. Respond as a thoughtful friend who truly understands both their writing and their current question.
        
        Journal Entry:
        \(journalEntry.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        
        // Add conversation history for context (limited to prevent token overflow)
        if !conversationHistory.isEmpty {
            prompt += "\n\nPrevious conversation:"
            for message in conversationHistory.suffix(Constants.maxConversationHistory - 2) {
                let role = message.isUser ? "User" : "Assistant"
                prompt += "\n\(role): \(message.content)"
            }
        }
        
        prompt += "\n\nUser's current message: \(userMessage)"
        prompt += "\n\nPlease respond to their specific question while drawing insights from their journal entry:"
        
        return prompt
    }
    
    func callOpenAIAPI(message: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw APIError.invalidURL
        }
        
        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "user", "content": message]
            ],
            "max_tokens": Constants.maxTokensPerRequest,
            "temperature": 0.7
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        // Add debugging
        print("Making request to: \(url)")
        print("Request headers: \(request.allHTTPHeaderFields ?? [:])")
        print("API Key prefix: \(String(apiKey.prefix(10)))...")
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("Response status code: \(httpResponse.statusCode)")
                print("Response headers: \(httpResponse.allHeaderFields)")
            }
            
            if let responseString = String(data: data, encoding: .utf8) {
                print("Response body: \(responseString)")
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.requestFailed("No HTTP response received")
            }
            
            guard httpResponse.statusCode == 200 else {
                // Parse error response for detailed error information
                if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = errorData["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    
                    // Handle specific error types
                    switch httpResponse.statusCode {
                    case 401:
                        throw APIError.authenticationError
                    case 429:
                        throw APIError.quotaExceeded
                    case 500...599:
                        throw APIError.serverError(httpResponse.statusCode)
                    default:
                        throw APIError.requestFailed(message)
                    }
                } else {
                    switch httpResponse.statusCode {
                    case 401:
                        throw APIError.authenticationError
                    case 429:
                        throw APIError.quotaExceeded
                    case 500...599:
                        throw APIError.serverError(httpResponse.statusCode)
                    default:
                        throw APIError.requestFailed("Request failed with status \(httpResponse.statusCode)")
                    }
                }
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw APIError.invalidResponse
            }
            
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("Network error: \(error)")
            print("Error description: \(error.localizedDescription)")
            throw error
        }
    }
    
    func callAnthropicAPI(message: String, apiKey: String) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw APIError.invalidURL
        }
        
        let payload: [String: Any] = [
            "model": "claude-3-haiku-20240307",
            "max_tokens": Constants.maxTokensPerRequest,
            "messages": [
                ["role": "user", "content": message]
            ]
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await urlSession.data(for: request)
        
        // Add debugging for Claude API
        if let httpResponse = response as? HTTPURLResponse {
            print("Claude API Response status: \(httpResponse.statusCode)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("Claude API Response: \(responseString)")
            }
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.requestFailed("No HTTP response received")
        }
        
        guard httpResponse.statusCode == 200 else {
            // Parse error response for detailed error information
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorData["error"] as? [String: Any],
               let message = error["message"] as? String {
                
                // Handle specific error types
                switch httpResponse.statusCode {
                case 401:
                    throw APIError.authenticationError
                case 429:
                    throw APIError.quotaExceeded
                case 500...599:
                    throw APIError.serverError(httpResponse.statusCode)
                default:
                    throw APIError.requestFailed(message)
                }
            } else {
                switch httpResponse.statusCode {
                case 401:
                    throw APIError.authenticationError
                case 429:
                    throw APIError.quotaExceeded
                case 500...599:
                    throw APIError.serverError(httpResponse.statusCode)
                default:
                    throw APIError.requestFailed("Request failed with status \(httpResponse.statusCode)")
                }
            }
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw APIError.invalidResponse
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
} 