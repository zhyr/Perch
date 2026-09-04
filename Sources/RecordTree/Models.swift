import Foundation

/// 一个分段 = 一次复制内容（chunk）
struct ChunkRec: Identifiable {
    let id: String
    let maintreeID: String
    let content: String
    /// 附件相对路径（图片为 images/<day>/<file>.png，无附件为空串）
    let attachment: String
    let sourceApp: String
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let lastCopiedMs: Int64?

    var isImage: Bool { !attachment.isEmpty }
}

/// 一棵记录树 = 若干 chunk 的聚合（maintree）
struct TreeRec: Identifiable {
    let id: String
    let title: String
    let archivedAtMs: Int64?
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let chunks: [ChunkRec]

    var isArchived: Bool { (archivedAtMs ?? 0) > 0 }
    var latest: ChunkRec? { chunks.max { $0.updatedAtMs < $1.updatedAtMs } }
}

/// DataStore 返回的搜索结果
struct SearchResult {
    let chunkID: String
    let treeID: String
    let treeTitle: String
    let content: String
    let sourceApp: String
    let chunkUpdatedAtMs: Int64
    let treeUpdatedAtMs: Int64
}

/// 一次变更影响（用于决定 Markdown 归档范围）
struct MutationInfo {
    let treeID: String
    let chunkID: String?
    let newTree: Bool
    let oldDay: String
    let newDay: String

    var affectedDays: [String] {
        oldDay == newDay ? [newDay] : [newDay, oldDay]
    }
}
