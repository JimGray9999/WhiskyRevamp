//
//  WhiskyWineInstaller.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import SemanticVersion

public enum WhiskyWineDownloadError: Error, LocalizedError {
    case downloadFailed
    case invalidArchive
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Could not download WhiskyWine. The hosting server may be unavailable."
        case .invalidArchive:
            return "Downloaded file is not a valid WhiskyWine archive."
        case .installFailed(let message):
            return "Failed to install WhiskyWine: \(message)"
        }
    }
}

public class WhiskyWineInstaller {
    /// The Whisky application folder
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: Bundle.whiskyBundleIdentifier)

    /// The folder of all the libfrary files
    public static let libraryFolder = applicationFolder.appending(path: "Libraries")

    /// URL to the installed `wine` `bin` directory
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    private static let librariesTarGzURLs: [URL] = [
        staticURL("https://data.getwhisky.app/Wine/Libraries.tar.gz"),
        staticURL("https://web.archive.org/web/20250824114303/" +
            "https://data.getwhisky.app/Wine/Libraries.tar.gz")
    ]

    private static let versionPlistURLs: [URL] = [
        staticURL("https://data.getwhisky.app/Wine/WhiskyWineVersion.plist"),
        staticURL("https://web.archive.org/web/20260404034109/" +
            "https://data.getwhisky.app/Wine/WhiskyWineVersion.plist")
    ]

    private static func staticURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid static WhiskyWine URL: \(string)")
        }
        return url
    }

    public static func isWhiskyWineInstalled() -> Bool {
        return whiskyWineVersion() != nil
    }

    public static func downloadLibraries(
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        for url in librariesTarGzURLs {
            do {
                let tempURL = try await downloadFile(from: url, onProgress: onProgress)
                if try isGzipArchive(at: tempURL) {
                    return tempURL
                }
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                print("Failed to download WhiskyWine from \(url): \(error)")
            }
        }

        throw WhiskyWineDownloadError.downloadFailed
    }

    private static func downloadFile(
        from url: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let destinationURL = FileManager.default.temporaryDirectory
                .appending(path: "WhiskyWine-download-\(UUID().uuidString).tar.gz")
            let delegate = DownloadDelegate(
                destinationURL: destinationURL,
                onProgress: onProgress,
                continuation: continuation
            )
            let session = URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil
            )
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destinationURL: URL
        private let onProgress: (@Sendable (Int64, Int64) -> Void)?
        private var continuation: CheckedContinuation<URL, Error>?
        private var hasResumed = false
        var session: URLSession?

        init(
            destinationURL: URL,
            onProgress: (@Sendable (Int64, Int64) -> Void)?,
            continuation: CheckedContinuation<URL, Error>
        ) {
            self.destinationURL = destinationURL
            self.onProgress = onProgress
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                resumeOnce(.failure(WhiskyWineDownloadError.downloadFailed))
                return
            }

            do {
                try FileManager.default.moveItem(at: location, to: destinationURL)
                resumeOnce(.success(destinationURL))
            } catch {
                resumeOnce(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                resumeOnce(.failure(error))
            }
            self.session?.invalidateAndCancel()
        }

        private func resumeOnce(_ result: Result<URL, Error>) {
            guard !hasResumed else { return }
            hasResumed = true
            switch result {
            case .success(let url):
                continuation?.resume(returning: url)
            case .failure(let error):
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }
    }

    @discardableResult
    public static func install(from: URL) -> Bool {
        do {
            guard try isGzipArchive(at: from) else {
                print("Failed to install WhiskyWine: \(WhiskyWineDownloadError.invalidArchive.localizedDescription)")
                return false
            }

            let fileManager = FileManager.default
            let tempInstallURL = fileManager.temporaryDirectory
                .appending(path: "WhiskyWine-install-\(UUID().uuidString)")

            try fileManager.createDirectory(at: tempInstallURL, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tempInstallURL) }

            try Tar.untar(tarBall: from, toURL: tempInstallURL)

            let installedLibraries = tempInstallURL.appending(path: "Libraries")
            let versionPlist = installedLibraries
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")
            guard fileManager.fileExists(atPath: versionPlist.path) else {
                throw WhiskyWineDownloadError.installFailed("Archive is missing WhiskyWineVersion.plist")
            }

            if fileManager.fileExists(atPath: applicationFolder.path) {
                try fileManager.removeItem(at: applicationFolder)
            }
            try fileManager.moveItem(at: tempInstallURL, to: applicationFolder)
            try? fileManager.removeItem(at: from)

            return true
        } catch {
            print("Failed to install WhiskyWine: \(error)")
            return false
        }
    }

    private static func isGzipArchive(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 2), header.count == 2 else {
            return false
        }
        return header[0] == 0x1f && header[1] == 0x8b
    }

    private static func fetchData(from urls: [URL]) async -> Data? {
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    return data
                }
            } catch {
                print("Failed to fetch \(url): \(error)")
            }
        }
        return nil
    }

    public static func uninstall() {
        do {
            try FileManager.default.removeItem(at: libraryFolder)
        } catch {
            print("Failed to uninstall WhiskyWine: \(error)")
        }
    }

    public static func shouldUpdateWhiskyWine() async -> (Bool, SemanticVersion) {
        let localVersion = whiskyWineVersion()
        var remoteVersion: SemanticVersion?

        if let data = await fetchData(from: versionPlistURLs) {
            do {
                let decoder = PropertyListDecoder()
                let remoteInfo = try decoder.decode(WhiskyWineVersion.self, from: data)
                remoteVersion = remoteInfo.version
            } catch {
                print(error)
            }
        }

        if let localVersion = localVersion, let remoteVersion = remoteVersion {
            if localVersion < remoteVersion {
                return (true, remoteVersion)
            }
        }

        return (false, SemanticVersion(0, 0, 0))
    }

    public static func whiskyWineVersion() -> SemanticVersion? {
        do {
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            let info = try decoder.decode(WhiskyWineVersion.self, from: data)
            return info.version
        } catch {
            print(error)
            return nil
        }
    }
}

struct WhiskyWineVersion: Codable {
    var version: SemanticVersion = SemanticVersion(1, 0, 0)
}
