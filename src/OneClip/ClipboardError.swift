import Foundation

enum ClipboardError: LocalizedError {
    case accessDenied
    case dataCorrupted
    case storageFailure
    case imageProcessingFailed
    case permissionRequired
    case fileOperationFailed
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return AppLanguage.text("剪贴板访问被拒绝", "Clipboard access was denied")
        case .dataCorrupted:
            return AppLanguage.text("剪贴板数据损坏", "Clipboard data is damaged")
        case .storageFailure:
            return AppLanguage.text("存储操作失败", "Storage operation failed")
        case .imageProcessingFailed:
            return AppLanguage.text("图像处理失败", "Image processing failed")
        case .permissionRequired:
            return AppLanguage.text("需要辅助功能权限", "Accessibility permission is required")
        case .fileOperationFailed:
            return AppLanguage.text("文件操作失败", "File operation failed")
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .accessDenied, .permissionRequired:
            return AppLanguage.text("请在系统设置中授予应用权限", "Grant the app permission in System Settings")
        case .dataCorrupted:
            return AppLanguage.text("请重新复制内容", "Copy the content again")
        case .storageFailure:
            return AppLanguage.text("请检查磁盘空间", "Check available disk space")
        case .imageProcessingFailed:
            return AppLanguage.text("请尝试复制其他格式的图片", "Try copying an image in a different format")
        case .fileOperationFailed:
            return AppLanguage.text("请检查文件是否存在且有权限访问", "Check that the file exists and you have permission to access it")
        }
    }
}

