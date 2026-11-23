import Foundation
import TileKit
import Darwin

private struct Arguments {
    let command: String
    let paths: [String]
    let options: [String: String]
    init(_ values: [String]) throws {
        guard let command = values.first else { throw ToolError.usage }
        self.command = command
        var paths: [String] = [], options: [String: String] = [:], index = 1
        let flags: Set<String> = ["--full", "--help"]
        let known: Set<String> = ["--samples", "--checkpoint", "--max-records", "--bounds", "--zooms", "--max-tiles", "--port"]
        while index < values.count {
            let value = values[index]
            if flags.contains(value) { options[value] = "1" }
            else if value.hasPrefix("--") {
                guard known.contains(value), index + 1 < values.count, options[value] == nil else { throw ToolError.invalid(value) }
                index += 1; options[value] = values[index]
            } else { paths.append(value) }
            index += 1
        }
        self.paths = paths; self.options = options
    }
    func integer(_ key: String, default fallback: Int, maximum: Int = .max) throws -> Int {
        guard let value = options[key] else { return fallback }
        guard let number = Int(value), number > 0, number <= maximum else { throw ToolError.invalid(key) }
        return number
    }
    var bounds: GeoBounds? {
        get throws {
            guard let value = options["--bounds"] else { return nil }
            let numbers = value.split(separator: ",").compactMap { Double($0) }
            guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[0] >= -180, numbers[2] <= 180,
                  numbers[1] >= -90, numbers[3] <= 90, numbers[0] < numbers[2], numbers[1] < numbers[3] else { throw ToolError.invalid("--bounds") }
            return GeoBounds(west: numbers[0], south: numbers[1], east: numbers[2], north: numbers[3])
        }
    }
    var zooms: ClosedRange<Int>? {
        get throws {
            guard let value = options["--zooms"] else { return nil }
            let numbers = value.split(separator: ":").compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] >= 0, numbers[1] <= 30, numbers[0] <= numbers[1] else { throw ToolError.invalid("--zooms") }
            return numbers[0]...numbers[1]
        }
    }
}
private enum ToolError: Error { case usage, invalid(String) }
private let usage = """
tiletools inspect INPUT
tiletools check INPUT [--samples 128] [--bounds W,S,E,N] [--zooms MIN:MAX]
tiletools check ARCHIVE.zip --full [--checkpoint REPORT.json] [--max-records COUNT]
tiletools extract INPUT OUTPUT_DIRECTORY --bounds W,S,E,N --zooms MIN:MAX [--max-tiles 1000000]
tiletools serve INPUT [--port 8766]

check is read-only. --full checks every ZIP entry's CRC and decodes image entries; a checkpoint
can resume the same archive after interruption. Samples do not certify full integrity.
extract writes per-level ZIP64 archives and manifest.json; OUTPUT_DIRECTORY must not exist.
serve binds only 127.0.0.1 and supports directories, ZIP datasets and raster MBTiles.
"""
private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value)); FileHandle.standardOutput.write(Data("\n".utf8))
}
private func run(_ args: Arguments) async throws -> Bool {
    if args.command == "help" || args.options["--help"] != nil { print(usage); return true }
    guard let input = args.paths.first else { throw ToolError.usage }
    let url = URL(fileURLWithPath: input)
    switch args.command {
    case "inspect":
        guard args.paths.count == 1 else { throw ToolError.usage }
        if url.pathExtension.lowercased() == "zip" {
            let archive = try ZipArchive(url: url)
            try printJSON(["source": url.path, "entries": String(archive.entryCount), "rows": String(archive.indexedRows.count),
                           "directoryBytes": String(archive.centralDirectorySize), "zip64": String(archive.isZip64)])
        } else {
            let dataset = try TileDataTools.dataset(at: url)
            try printJSON(["name": dataset.name, "source": dataset.id, "grid": dataset.grid.kind.rawValue,
                           "zooms": "\(dataset.zoomRange.lowerBound):\(dataset.zoomRange.upperBound)", "tileSize": String(dataset.layout.tileSize)])
        }
        return true
    case "check":
        guard args.paths.count == 1 else { throw ToolError.usage }
        if url.pathExtension.lowercased() == "zip", args.options["--bounds"] == nil {
            let checkpoint = args.options["--checkpoint"].map { URL(fileURLWithPath: $0) }
            let records = try args.options["--max-records"].map { _ in try args.integer("--max-records", default: 128) }
            let count = try args.integer("--samples", default: 128, maximum: 100_000)
            let report = try await cancellable {
                try ArchiveAudit.run(url: url, full: args.options["--full"] != nil, sampleCount: count,
                                     checkpoint: checkpoint, maximumRecords: records)
            }
            try printJSON(report); return report.failureCount == 0
        }
        guard args.options["--full"] == nil, args.options["--checkpoint"] == nil else {
            throw ToolError.invalid("--full / --checkpoint require a ZIP archive")
        }
        let dataset = try TileDataTools.dataset(at: url)
        let report = try await TileDataTools.checkCoverage(dataset: dataset, bounds: args.bounds, zoomRange: args.zooms,
                                                         samples: args.integer("--samples", default: 128, maximum: 100_000))
        try printJSON(report); return report["unreadable"] == 0 && report["missing"] == 0
    case "extract":
        guard args.paths.count == 2, let bounds = try args.bounds, let zooms = try args.zooms else { throw ToolError.usage }
        let dataset = try TileDataTools.dataset(at: url)
        let report = try await TileSubsetExport.extract(dataset: dataset, bounds: bounds, zoomRange: zooms,
                                                       output: URL(fileURLWithPath: args.paths[1]),
                                                       maximumTiles: args.integer("--max-tiles", default: 1_000_000))
        try printJSON(report); return true
    case "serve":
        guard args.paths.count == 1 else { throw ToolError.usage }
        let dataset = try TileDataTools.dataset(at: url)
        let server = LocalTileServer()
        let port = try await server.startAsync(rootURL: dataset.rootURL, port: UInt16(args.integer("--port", default: 8766, maximum: 65_535)))
        defer { server.stop() }
        FileHandle.standardOutput.write(Data("http://127.0.0.1:\(port)/{z}/{x}/{y}.png\n".utf8))
        while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
        return true
    default: throw ToolError.usage
    }
}
private func cancellable<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(operation: body)
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

@main private struct TileToolsMain {
    static func main() async {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let work = Task { try await run(args) }
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            interrupt.setEventHandler { work.cancel() }; terminate.setEventHandler { work.cancel() }
            interrupt.resume(); terminate.resume()
            let success = try await work.value
            interrupt.cancel(); terminate.cancel()
            if !success { exit(2) }
        } catch is CancellationError { exit(130) }
        catch {
            FileHandle.standardError.write(Data("\(error)\n\(usage)\n".utf8)); exit(1)
        }
    }
}
