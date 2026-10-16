import Foundation

struct PortableManifest: Codable {
    var format: String
    var version: Int
    var projectName: String
    var deckPath: String
    var dependencies: [String]
    var createdAt: Date
}

enum PortableProjectError: LocalizedError {
    case invalidManifest(String)
    case unbundled([String], roots: [String])
    case unavailable([String])
    case unsafeArchive

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let message): return message
        case .unbundled(let paths, let roots):
            return "These files are outside the project folder, so the project would not be portable:\n\n" + paths.joined(separator: "\n") + "\n\nManimble checked these project roots:\n" + roots.joined(separator: "\n") + "\n\nMove them into the project folder and update the deck paths, then package it again."
        case .unavailable(let paths):
            return "Manimble could not read these dependencies. They may still be online-only Dropbox files:\n\n" + paths.joined(separator: "\n") + "\n\nDownload them locally, then try again."
        case .unsafeArchive:
            return "This .manimble file has unsafe or invalid archive paths and was not opened."
        }
    }
}

enum PortableProject {
    static let manifestName = "manimble-project.json"

    static func createFolder(workspace: Workspace, dependencies: [String], at destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw PortableProjectError.invalidManifest("A folder already exists at \(destination.path). Choose another location or remove it first.")
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try build(workspace: workspace, dependencies: dependencies, into: stage)
            try fm.moveItem(at: stage, to: destination)
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    static func createArchive(workspace: Workspace, dependencies: [String], at destination: URL) throws {
        let fm = FileManager.default
        let stageRoot = Workspace.base.appendingPathComponent("export/portable-\(UUID().uuidString)")
        let project = stageRoot.appendingPathComponent(workspace.projectName)
        let partial = destination.appendingPathExtension("partial")
        do {
            try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)
            try build(workspace: workspace, dependencies: dependencies, into: project)
            try? fm.removeItem(at: partial)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", project.path, partial.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw PortableProjectError.invalidManifest("The .manimble archive could not be created.")
            }
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: stageRoot)
            try? fm.removeItem(at: partial)
            throw error
        }
        try? fm.removeItem(at: stageRoot)
    }

    private static func build(workspace: Workspace, dependencies: [String], into project: URL) throws {
        let fm = FileManager.default
        let deckDestination = project.appendingPathComponent(workspace.deckRelativePath)
        try fm.createDirectory(at: deckDestination, withIntermediateDirectories: true)
        try copyDeck(from: workspace.work, to: deckDestination)

        // Assets are a conventional part of a Manim Slides project. Copy them
        // even if a slide did not access every file during the dependency scan.
        let assetSource = workspace.work.deletingLastPathComponent().appendingPathComponent("assets")
        if fm.fileExists(atPath: assetSource.path) {
            try copyNode(from: assetSource, to: project.appendingPathComponent(workspace.deckRelativePath.components(separatedBy: "/").dropLast().joined(separator: "/")).appendingPathComponent("assets"))
        }

        var outside: [String] = []
        var unavailable: [String] = []
        var included: [String] = []
        let rootPaths = [workspace.root.standardizedFileURL.path,
                         workspace.root.resolvingSymlinksInPath().standardizedFileURL.path]
        // The live workspace mirrors the original project's parent with
        // symlinks. Deck code can resolve those links and open files through
        // their original absolute paths, which sit outside `workspace.root`.
        // The portable layout mirrors that same parent, so those files are
        // still project files and should retain their relative paths.
        let sourceProjectRoot = workspace.original.deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.path
        let sourceProjectRoots = [sourceProjectRoot,
                                  URL(fileURLWithPath: sourceProjectRoot).resolvingSymlinksInPath().standardizedFileURL.path]
        for raw in Set(dependencies).sorted() {
            let source = URL(fileURLWithPath: raw).standardizedFileURL
            let candidates = [source.path, source.resolvingSymlinksInPath().standardizedFileURL.path]
            let roots = rootPaths + sourceProjectRoots
            guard let match = candidates.lazy.compactMap({ path in
                roots.first(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") })
                    .map { root in (path, root) }
            }).first else {
                outside.append(raw)
                continue
            }
            let (path, root) = match
            let prefix = root.hasSuffix("/") ? root : root + "/"
            let relative = String(path.dropFirst(prefix.count))
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  let attrs = try? fm.attributesOfItem(atPath: path), ((attrs[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
                unavailable.append(raw)
                continue
            }
            included.append(relative)
            let target = project.appendingPathComponent(relative)
            if fm.fileExists(atPath: target.path) { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }
        if !outside.isEmpty { throw PortableProjectError.unbundled(outside, roots: (rootPaths + sourceProjectRoots).sorted()) }
        if !unavailable.isEmpty { throw PortableProjectError.unavailable(unavailable) }

        let manifest = PortableManifest(
            format: "manimble-project", version: 1,
            projectName: workspace.projectName,
            deckPath: workspace.deckRelativePath,
            dependencies: included.sorted(), createdAt: Date()
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: project.appendingPathComponent(manifestName), options: .atomic)
    }

    private static func copyDeck(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        // Portable projects include existing Manim Slides builds and their
        // media so a recipient can present the deck before rendering it again.
        let excluded: Set<String> = ["snap", "__pycache__", ".manimble"]
        for name in try fm.contentsOfDirectory(atPath: source.path).sorted() where !name.hasPrefix(".") && !excluded.contains(name) {
            let child = source.appendingPathComponent(name)
            try copyNode(from: child, to: destination.appendingPathComponent(name))
        }
    }

    private static func copyNode(from source: URL, to destination: URL, depth: Int = 0) throws {
        guard depth < 64 else { throw PortableProjectError.invalidManifest("The project contains a directory link loop.") }
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true {
            let resolved = source.resolvingSymlinksInPath()
            guard resolved.path != source.path, fm.fileExists(atPath: resolved.path) else {
                throw PortableProjectError.invalidManifest("A project asset link is broken: \(source.path)")
            }
            try copyNode(from: resolved, to: destination, depth: depth + 1)
        } else if values.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in try fm.contentsOfDirectory(atPath: source.path).sorted() where !name.hasPrefix(".") && name != "__pycache__" {
                try copyNode(from: source.appendingPathComponent(name), to: destination.appendingPathComponent(name), depth: depth + 1)
            }
        } else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        }
    }

    static func deckURL(in project: URL) throws -> URL? {
        let manifestURL = project.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(PortableManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.format == "manimble-project", manifest.version == 1,
              !manifest.deckPath.hasPrefix("/"), !manifest.deckPath.split(separator: "/").contains("..") else {
            throw PortableProjectError.invalidManifest("This Manimble project has an unsupported or invalid manifest.")
        }
        let deck = project.appendingPathComponent(manifest.deckPath).standardizedFileURL
        let resolvedProject = project.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDeck = deck.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedDeck.path.hasPrefix(resolvedProject.path + "/"),
              FileManager.default.fileExists(atPath: deck.path) else {
            throw PortableProjectError.invalidManifest("The deck folder listed in this project is missing.")
        }
        return deck
    }

    static func unpackArchive(_ archive: URL) throws -> URL {
        let fm = FileManager.default
        let destination = Workspace.base.appendingPathComponent("projects/\(UUID().uuidString)")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let listing = Pipe()
        let list = Process(); list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z1", archive.path]; list.standardOutput = listing; list.standardError = FileHandle.nullDevice
        do { try list.run() } catch { throw PortableProjectError.unsafeArchive }
        let namesData = listing.fileHandleForReading.readDataToEndOfFile(); list.waitUntilExit()
        guard list.terminationStatus == 0,
              let names = String(data: namesData, encoding: .utf8)?.split(separator: "\n"),
              !names.isEmpty,
              names.allSatisfy({ name in
                  let s = String(name)
                  return !s.hasPrefix("/") && !s.split(separator: "/").contains("..") && !s.contains("\\")
              }) else {
            try? fm.removeItem(at: destination)
            throw PortableProjectError.unsafeArchive
        }
        let extract = Process(); extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", archive.path, destination.path]
        do { try extract.run(); extract.waitUntilExit() } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        guard extract.terminationStatus == 0 else {
            try? fm.removeItem(at: destination)
            throw PortableProjectError.unsafeArchive
        }
        let enumerator = fm.enumerator(at: destination, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if let deck = try deckURL(in: url) { return deck }
        }
        try? fm.removeItem(at: destination)
        throw PortableProjectError.invalidManifest("This archive does not contain a valid Manimble project.")
    }
}
