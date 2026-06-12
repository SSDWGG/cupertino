import ArgumentParser
import Foundation
import SampleIndex
import SearchAPI
import Services
import ServicesModels
import SharedConstants
import SQLite3

// MARK: - Export Showcase Data Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
extension CLIImpl.Command {
    struct ExportShowcaseData: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export-showcase-data",
            abstract: "Export real Cupertino SQLite catalog into showcase JSON format"
        )

        private func exportDocsDatabase(
            dbURL: URL,
            sourceID: String,
            searchDatabaseFactory: any SearchModule.DatabaseFactory,
            frameworks: inout [String: [String]],
            documents: inout [String: [String]],
            contents: inout [String: String]
        ) async throws {
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                print("Skipping \(sourceID): Database not found.")
                return
            }
            print("Reading \(dbURL.lastPathComponent)...")
            let (dbFrameworks, _) = try await Services.ServiceContainer.withDocsService(
                dbURL: dbURL,
                searchDatabaseFactory: searchDatabaseFactory
            ) { service in
                let fws = try await service.listFrameworks()
                return (fws, 0)
            }

            // Take top 20 frameworks by document count
            let sortedFrameworks = dbFrameworks.sorted(by: { $0.value > $1.value })
            let topFws = sortedFrameworks.prefix(20).map(\.key)
            frameworks[sourceID] = Array(topFws)

            for fw in topFws {
                print("  Reading docs for \(sourceID) Framework/Topic: \(fw)...")
                let docs = try await Services.ServiceContainer.withDocsService(
                    dbURL: dbURL,
                    searchDatabaseFactory: searchDatabaseFactory
                ) { service in
                    let page = try await service.listDocuments(source: sourceID, framework: fw.lowercased(), offset: 0, limit: 15)
                    return page.documents.map(\.title)
                }
                documents[fw.lowercased()] = docs

                let topDocURI = try await Services.ServiceContainer.withDocsService(
                    dbURL: dbURL,
                    searchDatabaseFactory: searchDatabaseFactory
                ) { service in
                    let page = try await service.listDocuments(source: sourceID, framework: fw.lowercased(), offset: 0, limit: 1)
                    return page.documents.first?.uri
                }
                if let topDocURI {
                    let text = try await Services.ServiceContainer.withDocsService(
                        dbURL: dbURL,
                        searchDatabaseFactory: searchDatabaseFactory
                    ) { service in
                        try await service.read(uri: topDocURI, format: .markdown)
                    }
                    if let text {
                        contents["\(sourceID)://\(fw.lowercased())/view"] = text
                    }
                }
            }
        }

        mutating func run() async throws {
            print("Exporting database data...")
            let searchDatabaseFactory: any SearchModule.DatabaseFactory = LiveSearchDatabaseFactory()
            let sampleDatabaseFactory: any Sample.Index.DatabaseFactory = LiveSampleIndexDatabaseFactory()
            let baseDirectory = Shared.Paths.live().baseDirectory
            let appleDocsURL = CLIImpl.resolveAppleDocsDBURL()

            var frameworks: [String: [String]] = [:]
            var documents: [String: [String]] = [:]
            var contents: [String: String] = [:]

            // 1. Fetch Apple Docs
            try await exportDocsDatabase(
                dbURL: appleDocsURL,
                sourceID: "apple-docs",
                searchDatabaseFactory: searchDatabaseFactory,
                frameworks: &frameworks,
                documents: &documents,
                contents: &contents
            )

            // 2. Fetch HIG Topics
            let higURL = baseDirectory.appendingPathComponent("hig.db")
            try await exportDocsDatabase(
                dbURL: higURL,
                sourceID: "hig",
                searchDatabaseFactory: searchDatabaseFactory,
                frameworks: &frameworks,
                documents: &documents,
                contents: &contents
            )

            // 3. Fetch Apple Archive
            let archiveURL = baseDirectory.appendingPathComponent("apple-archive.db")
            try await exportDocsDatabase(
                dbURL: archiveURL,
                sourceID: "apple-archive",
                searchDatabaseFactory: searchDatabaseFactory,
                frameworks: &frameworks,
                documents: &documents,
                contents: &contents
            )

            // 4. Fetch Swift Evolution
            let swiftEvolutionURL = baseDirectory.appendingPathComponent("swift-evolution.db")
            try await exportDocsDatabase(
                dbURL: swiftEvolutionURL,
                sourceID: "swift-evolution",
                searchDatabaseFactory: searchDatabaseFactory,
                frameworks: &frameworks,
                documents: &documents,
                contents: &contents
            )

            // 5. Fetch Swift.org
            let swiftOrgURL = baseDirectory.appendingPathComponent("swift-org.db")
            try await exportDocsDatabase(
                dbURL: swiftOrgURL,
                sourceID: "swift-org",
                searchDatabaseFactory: searchDatabaseFactory,
                frameworks: &frameworks,
                documents: &documents,
                contents: &contents
            )

            // 6. Fetch Swift Book
            let swiftBookURL = baseDirectory.appendingPathComponent("swift-book.db")
            try await exportDocsDatabase(
                dbURL: swiftBookURL,
                sourceID: "swift-book",
                searchDatabaseFactory: searchDatabaseFactory,
                frameworks: &frameworks,
                documents: &documents,
                contents: &contents
            )

            // 7. Fetch Sample Projects
            let sampleDbURL = Sample.Index.databasePath(baseDirectory: baseDirectory)
            if FileManager.default.fileExists(atPath: sampleDbURL.path) {
                print("Reading apple-sample-code.db...")
                let projects = try await Services.ServiceContainer.withSampleService(
                    samplesDB: sampleDbURL,
                    sampleDatabaseFactory: sampleDatabaseFactory
                ) { service in
                    try await service.listProjects(framework: nil, limit: 15)
                }

                let projectNames = projects.map(\.title)
                frameworks["samples"] = projectNames

                for project in projects {
                    print("  Reading files for Sample Project: \(project.title)...")
                    let files = try await Services.ServiceContainer.withSampleService(
                        samplesDB: sampleDbURL,
                        sampleDatabaseFactory: sampleDatabaseFactory
                    ) { service in
                        try await service.listFiles(projectId: project.id, folder: nil)
                    }
                    documents[project.title.lowercased()] = files.prefix(15).map(\.path)

                    if let readme = project.readme, !readme.isEmpty {
                        contents["samples://\(project.title.lowercased())/view"] = readme
                    }
                }
            }

            // 8. Fetch Packages (packages.db)
            let packagesURL = baseDirectory.appendingPathComponent("packages.db")
            if FileManager.default.fileExists(atPath: packagesURL.path) {
                print("Reading packages.db...")
                var db: OpaquePointer?
                if sqlite3_open_v2(packagesURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                    defer { sqlite3_close(db) }

                    let sql = """
                    SELECT id, owner, repo FROM package_metadata
                    ORDER BY stars DESC, owner, repo
                    LIMIT 20;
                    """
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                        var pkgs: [String] = []
                        var pkgIds: [String: Int] = [:]
                        while sqlite3_step(stmt) == SQLITE_ROW {
                            let pkgId = Int(sqlite3_column_int(stmt, 0))
                            if let ownerPtr = sqlite3_column_text(stmt, 1),
                               let repoPtr = sqlite3_column_text(stmt, 2) {
                                let owner = String(cString: ownerPtr)
                                let repo = String(cString: repoPtr)
                                let fullName = "\(owner)/\(repo)"
                                pkgs.append(fullName)
                                pkgIds[fullName] = pkgId
                            }
                        }
                        sqlite3_finalize(stmt)

                        frameworks["packages"] = pkgs

                        for pkg in pkgs {
                            let pkgId = pkgIds[pkg] ?? 0
                            print("  Reading files for Package: \(pkg)...")
                            let fileSql = """
                            SELECT relpath FROM package_files
                            WHERE package_id = ?
                            ORDER BY relpath
                            LIMIT 15;
                            """
                            var fileStmt: OpaquePointer?
                            if sqlite3_prepare_v2(db, fileSql, -1, &fileStmt, nil) == SQLITE_OK {
                                sqlite3_bind_int(fileStmt, 1, Int32(pkgId))
                                var pkgFiles: [String] = []
                                while sqlite3_step(fileStmt) == SQLITE_ROW {
                                    if let relpathPtr = sqlite3_column_text(fileStmt, 0) {
                                        pkgFiles.append(String(cString: relpathPtr))
                                    }
                                }
                                sqlite3_finalize(fileStmt)
                                documents[pkg.lowercased()] = pkgFiles
                            }

                            let contentSql = """
                            SELECT f.content
                            FROM package_files_fts f
                            JOIN package_files pf ON pf.relpath = f.relpath AND pf.package_id = ?
                            WHERE f.owner = ? AND f.repo = ? AND f.relpath LIKE '%README.md%'
                            LIMIT 1;
                            """
                            var contentStmt: OpaquePointer?
                            var contentFound = false
                            if sqlite3_prepare_v2(db, contentSql, -1, &contentStmt, nil) == SQLITE_OK {
                                let parts = pkg.split(separator: "/")
                                if parts.count == 2 {
                                    sqlite3_bind_int(contentStmt, 1, Int32(pkgId))
                                    sqlite3_bind_text(contentStmt, 2, (String(parts[0]) as NSString).utf8String, -1, nil)
                                    sqlite3_bind_text(contentStmt, 3, (String(parts[1]) as NSString).utf8String, -1, nil)

                                    if sqlite3_step(contentStmt) == SQLITE_ROW {
                                        if let contentPtr = sqlite3_column_text(contentStmt, 0) {
                                            let readme = String(cString: contentPtr)
                                            contents["packages://\(pkg.lowercased())/view"] = readme
                                            contentFound = true
                                        }
                                    }
                                }
                                sqlite3_finalize(contentStmt)
                            }

                            if !contentFound {
                                let fallbackSql = """
                                SELECT content FROM package_files_fts
                                WHERE owner = ? AND repo = ?
                                LIMIT 1;
                                """
                                var fallbackStmt: OpaquePointer?
                                if sqlite3_prepare_v2(db, fallbackSql, -1, &fallbackStmt, nil) == SQLITE_OK {
                                    let parts = pkg.split(separator: "/")
                                    if parts.count == 2 {
                                        sqlite3_bind_text(fallbackStmt, 1, (String(parts[0]) as NSString).utf8String, -1, nil)
                                        sqlite3_bind_text(fallbackStmt, 2, (String(parts[1]) as NSString).utf8String, -1, nil)

                                        if sqlite3_step(fallbackStmt) == SQLITE_ROW {
                                            if let contentPtr = sqlite3_column_text(fallbackStmt, 0) {
                                                contents["packages://\(pkg.lowercased())/view"] = String(cString: contentPtr)
                                            }
                                        }
                                    }
                                    sqlite3_finalize(fallbackStmt)
                                }
                            }
                        }
                    }
                }
            }

            // 9. Dump to real-data.json
            let output: [String: Any] = [
                "frameworks": frameworks,
                "documents": documents,
                "contents": contents,
            ]

            let jsonWriter = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            let destURL = URL(fileURLWithPath: "/Volumes/Code/DeveloperExt/public/cupertino-desktop/real-data.json")
            try jsonWriter.write(to: destURL)
            print("Successfully exported real database catalog data to \(destURL.path)!")
        }
    }
}
