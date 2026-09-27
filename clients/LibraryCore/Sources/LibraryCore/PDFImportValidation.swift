import Foundation
import PDFKit

public enum PDFImportError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case passwordRequired
    case corrupt
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .tooLarge:
            return "PDF 超过 50 MB（50,000,000 字节）上限，请选择较小的文件。"
        case .passwordRequired:
            return "此 PDF 需要打开密码，当前无法导入。请先用可解锁的 PDF 阅读器解锁并另存无需打开密码的副本，再重新导入；原文件未修改。"
        case .corrupt:
            return "无法读取此 PDF 的页面，文件可能损坏或不是有效的 PDF。请在 PDF 阅读器中检查后重新导入。"
        case .unreadable:
            return "无法读取所选 PDF，请确认文件仍存在、已下载到本机且允许访问，再重新选择。"
        }
    }
}

/// Validates the bytes that will actually be stored, without rewriting the original.
public enum PDFImportValidation {
    /// A dismissed picker or an empty selection is not a failed save.
    public static func revisionFile(from result: Result<[URL], Error>) -> Result<URL?, Error> {
        switch result {
        case .success(let urls):
            return .success(urls.first)
        case .failure(let error):
            if isUserCancellation(error) { return .success(nil) }
            return .failure(error)
        }
    }

    public static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError
    }

    public static let maximumByteCount = 50_000_000

    public static func read(url: URL) throws -> Data {
        let values: URLResourceValues
        let handle: FileHandle
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw PDFImportError.unreadable }
            if let size = values.fileSize, size > maximumByteCount { throw PDFImportError.tooLarge }
            handle = try FileHandle(forReadingFrom: url)
        } catch let error as PDFImportError { throw error }
        catch { throw PDFImportError.unreadable }
        defer { try? handle.close() }

        // Read at most the limit plus one byte even if the file grows after the
        // resource-value snapshot. The extra byte distinguishes the exact limit
        // from an oversized file without loading all of an unbounded source.
        var data = Data()
        if let size = values.fileSize { data.reserveCapacity(min(size, maximumByteCount + 1)) }
        do {
            while let chunk = try handle.read(upToCount: min(1_048_576, maximumByteCount + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumByteCount else { throw PDFImportError.tooLarge }
            }
        } catch let error as PDFImportError { throw error }
        catch { throw PDFImportError.unreadable }
        try validate(data: data)
        return data
    }

    public static func validate(data: Data) throws {
        guard data.count <= maximumByteCount else { throw PDFImportError.tooLarge }
        guard let document = PDFDocument(data: data) else { throw PDFImportError.corrupt }
        // An owner-password-only PDF may already be readable. Only an actual
        // opening-password requirement prevents import; isEncrypted alone does not.
        guard !document.isLocked else { throw PDFImportError.passwordRequired }
        guard document.pageCount > 0, document.page(at: 0) != nil else { throw PDFImportError.corrupt }
    }
}
