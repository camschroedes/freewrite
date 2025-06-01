// ConversationCache.swift
//  freewrite
//
//  Efficient file-based conversation cache following Swift memory management best practices
//

import Foundation

/// Efficient file-based conversation cache following Swift memory management best practices
class ConversationCache {
    
    // MARK: - Properties
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var memoryCache: [UUID: APIService.ConversationContext] = [:]
    private let maxMemoryCache = 5 // Limit in-memory cache to prevent memory bloat
    
    // MARK: - Initialization
    init() {
        // Create cache directory using lazy initialization pattern
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        cacheDirectory = documentsDir.appendingPathComponent("ChatCache")
        
        createCacheDirectoryIfNeeded()
    }
    
    // MARK: - Public Methods
    
    /// Saves conversation with efficient memory management
    func saveConversation(_ context: APIService.ConversationContext, for id: UUID) {
        // Use background queue to avoid blocking UI
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performSave(context, for: id)
        }
        
        // Update memory cache with LRU eviction
        updateMemoryCache(context, for: id)
    }
    
    /// Gets conversation using lazy loading pattern
    func getConversation(id: UUID) -> APIService.ConversationContext? {
        // Check memory cache first (fastest)
        if let cached = memoryCache[id] {
            return cached
        }
        
        // Lazy load from disk if not in memory
        return loadFromDisk(id: id)
    }
    
    /// Removes conversation and frees memory
    func removeConversation(id: UUID) {
        // Remove from memory cache
        memoryCache.removeValue(forKey: id)
        
        // Remove from disk
        let fileURL = cacheDirectory.appendingPathComponent("\(id.uuidString).json")
        try? fileManager.removeItem(at: fileURL)
    }
    
    /// Clears old conversations to manage storage space
    func clearOldConversations(olderThan days: Int = 30) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performCleanup(olderThan: cutoffDate)
        }
    }
}

// MARK: - Private Methods
private extension ConversationCache {
    
    func createCacheDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }
    
    func performSave(_ context: APIService.ConversationContext, for id: UUID) {
        let fileURL = cacheDirectory.appendingPathComponent("\(id.uuidString).json")
        
        do {
            let data = try JSONEncoder().encode(context)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save conversation: \(error)")
        }
    }
    
    func updateMemoryCache(_ context: APIService.ConversationContext, for id: UUID) {
        memoryCache[id] = context
        
        // Implement LRU eviction to prevent memory bloat
        if memoryCache.count > maxMemoryCache {
            // Remove oldest conversation from memory (not disk)
            if let oldestKey = memoryCache.keys.min(by: { 
                memoryCache[$0]?.createdAt ?? Date() < memoryCache[$1]?.createdAt ?? Date() 
            }) {
                memoryCache.removeValue(forKey: oldestKey)
            }
        }
    }
    
    func loadFromDisk(id: UUID) -> APIService.ConversationContext? {
        let fileURL = cacheDirectory.appendingPathComponent("\(id.uuidString).json")
        
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let context = try JSONDecoder().decode(APIService.ConversationContext.self, from: data)
            
            // Cache in memory for future access
            memoryCache[id] = context
            
            return context
        } catch {
            print("Failed to load conversation: \(error)")
            return nil
        }
    }
    
    func performCleanup(olderThan cutoffDate: Date) {
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.creationDateKey])
            
            for fileURL in fileURLs {
                let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey])
                if let creationDate = resourceValues.creationDate,
                   creationDate < cutoffDate {
                    try fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Failed to cleanup old conversations: \(error)")
        }
    }
} 