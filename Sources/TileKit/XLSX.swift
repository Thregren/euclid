import Foundation

/// 极简 XLSX（OOXML 电子表格）生成器。
///
/// 不引入任何第三方依赖：先按 OOXML 规范拼出工作表的 XML 部件，
/// 再用文件内自带的 ZIP 打包器（仅存储、不压缩）装成一个 `.xlsx`。
/// 生成的文件可以被 Excel、Numbers、WPS、LibreOffice 直接打开。
public enum XLSX {
    /// 单元格内容。
    public enum Cell: Sendable, Hashable {
        /// 文本。
        case text(String)
        /// 数字，按常规小数显示。
        case number(Double)
        /// 数字，按 8 位小数显示（经纬度等高精度值）。
        case precise(Double)
        /// 空单元格。
        case blank
    }

    /// 一张工作表。
    public struct Sheet: Sendable {
        public var name: String
        public var rows: [[Cell]]
        /// 是否冻结首行（表头）。
        public var freezesHeader: Bool

        public init(name: String, rows: [[Cell]], freezesHeader: Bool = true) {
            self.name = name
            self.rows = rows
            self.freezesHeader = freezesHeader
        }
    }

    /// 生成工作簿。
    public static func workbook(sheets: [Sheet]) -> Data {
        let usable = sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : sheets
        var parts: [(name: String, data: Data)] = []

        parts.append(("_rels/.rels", data(relationships)))
        parts.append(("[Content_Types].xml", data(contentTypes(sheetCount: usable.count))))
        parts.append(("xl/workbook.xml", data(workbook(sheets: usable))))
        parts.append(("xl/_rels/workbook.xml.rels", data(workbookRelationships(sheetCount: usable.count))))
        parts.append(("xl/styles.xml", data(styles)))
        for (index, sheet) in usable.enumerated() {
            parts.append(("xl/worksheets/sheet\(index + 1).xml", data(worksheet(sheet, index: index))))
        }
        return ZIP.stored(parts)
    }

    // MARK: - 部件

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    private static let relationships = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static func contentTypes(sheetCount: Int) -> String {
        var overrides = """
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        """
        for index in 1...max(1, sheetCount) {
            overrides += "\n  <Override PartName=\"/xl/worksheets/sheet\(index).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
        \(overrides)
        </Types>
        """
    }

    private static func workbook(sheets: [Sheet]) -> String {
        let entries = sheets.enumerated().map { index, sheet in
            "\n    <sheet name=\"\(xmlEscape(sheetName(sheet.name, index: index)))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return xmlHeader + """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>\(entries)
          </sheets>
        </workbook>
        """
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        var entries = ""
        for index in 1...max(1, sheetCount) {
            entries += "\n  <Relationship Id=\"rId\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index).xml\"/>"
        }
        entries += "\n  <Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        return xmlHeader + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(entries)
        </Relationships>
        """
    }

    /// 样式表：0 普通、1 加粗表头、2 八位小数、3 常规小数。
    private static let styles = xmlHeader + """
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <numFmts count="2">
        <numFmt numFmtId="164" formatCode="0.00000000"/>
        <numFmt numFmtId="165" formatCode="#,##0.000"/>
      </numFmts>
      <fonts count="2">
        <font><sz val="11"/><color theme="1"/><name val="Helvetica Neue"/><family val="2"/></font>
        <font><b/><sz val="11"/><color theme="1"/><name val="Helvetica Neue"/><family val="2"/></font>
      </fonts>
      <fills count="2">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
      </fills>
      <borders count="1">
        <border><left/><right/><top/><bottom/><diagonal/></border>
      </borders>
      <cellStyleXfs count="1">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
      </cellStyleXfs>
      <cellXfs count="4">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      </cellXfs>
      <cellStyles count="1">
        <cellStyle name="Normal" xfId="0" builtinId="0"/>
      </cellStyles>
    </styleSheet>
    """

    private static func worksheet(_ sheet: Sheet, index: Int) -> String {
        var views = "<sheetViews><sheetView workbookViewId=\"0\">"
        if index == 0 { views = "<sheetViews><sheetView tabSelected=\"1\" workbookViewId=\"0\">" }
        if sheet.freezesHeader, sheet.rows.count > 1 {
            views += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        }
        views += "</sheetView></sheetViews>"

        var body = ""
        for (rowIndex, row) in sheet.rows.enumerated() {
            let isHeader = rowIndex == 0
            var cells = ""
            for (columnIndex, cell) in row.enumerated() where cell != .blank {
                let reference = "\(columnName(columnIndex))\(rowIndex + 1)"
                switch cell {
                case .text(let value):
                    let style = isHeader ? " s=\"1\"" : ""
                    cells += "<c r=\"\(reference)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                case .number(let value):
                    cells += "<c r=\"\(reference)\" s=\"3\"><v>\(number(value))</v></c>"
                case .precise(let value):
                    cells += "<c r=\"\(reference)\" s=\"2\"><v>\(number(value))</v></c>"
                case .blank:
                    break
                }
            }
            body += "\n    <row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }

        return xmlHeader + """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          \(views)
          <sheetFormatPr defaultRowHeight="15"/>
        \(columns(sheet.rows))
          <sheetData>\(body)
          </sheetData>
        </worksheet>
        """
    }

    private static func columns(_ rows: [[Cell]]) -> String {
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return "<cols/>" }
        var result = "<cols>"
        for index in 0..<columnCount {
            var widest = 6.0
            for row in rows where row.indices.contains(index) {
                let length = displayWidth(row[index])
                if length > widest { widest = length }
            }
            let width = min(max(widest + 2, 9), 42)
            result += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(String(format: "%.2f", width))\" customWidth=\"1\"/>"
        }
        return result + "</cols>"
    }

    private static func displayWidth(_ cell: Cell) -> Double {
        switch cell {
        case .text(let value):
            // 中日韩字符按两个字符宽度估算。
            return value.reduce(into: 0.0) { total, character in
                total += character.unicodeScalars.first.map { $0.value > 0x2E80 ? 2.0 : 1.0 } ?? 1.0
            }
        case .number(let value), .precise(let value):
            return Double(String(format: "%.3f", value).count)
        case .blank:
            return 0
        }
    }

    private static func sheetName(_ name: String, index: Int) -> String {
        // Excel 限制：不超过 31 个字符，且不能包含 : \ / ? * [ ]
        let forbidden: Set<Character> = [":", "\\", "/", "?", "*", "[", "]"]
        let cleaned = String(name.filter { !forbidden.contains($0) })
        let trimmed = cleaned.isEmpty ? "Sheet\(index + 1)" : cleaned
        return String(trimmed.prefix(31))
    }

    static func columnName(_ index: Int) -> String {
        var value = index
        var name = ""
        repeat {
            let scalar = UnicodeScalar(UInt8(65 + value % 26))
            name = String(Character(scalar)) + name
            value = value / 26 - 1
        } while value >= 0
        return name
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.10g", value)
    }

    static func xmlEscape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // XML 1.0 不接受这些控制字符，直接丢弃。
                if let scalar = character.unicodeScalars.first, scalar.value < 0x20,
                   scalar != "\t", scalar != "\n", scalar != "\r" {
                    continue
                }
                result.append(character)
            }
        }
        return result
    }
}

/// 仅供 xlsx 使用的 ZIP 打包器：只做「存储」，不做压缩。
///
/// OOXML 允许成员以 store 方式存放，省掉一整套 deflate 实现。
public enum ZIP {
    public static func stored(_ entries: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var directory = Data()
        // 固定为 2000-01-01 00:00:00 的 DOS 时间戳，保证输出可复现。
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x2821

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let checksum = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            output.appendLittleEndian(UInt32(0x0403_4B50))
            output.appendLittleEndian(UInt16(20))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(dosTime)
            output.appendLittleEndian(dosDate)
            output.appendLittleEndian(checksum)
            output.appendLittleEndian(size)
            output.appendLittleEndian(size)
            output.appendLittleEndian(UInt16(nameData.count))
            output.appendLittleEndian(UInt16(0))
            output.append(nameData)
            output.append(entry.data)

            directory.appendLittleEndian(UInt32(0x0201_4B50))
            directory.appendLittleEndian(UInt16(20))
            directory.appendLittleEndian(UInt16(20))
            directory.appendLittleEndian(UInt16(0))
            directory.appendLittleEndian(UInt16(0))
            directory.appendLittleEndian(dosTime)
            directory.appendLittleEndian(dosDate)
            directory.appendLittleEndian(checksum)
            directory.appendLittleEndian(size)
            directory.appendLittleEndian(size)
            directory.appendLittleEndian(UInt16(nameData.count))
            directory.appendLittleEndian(UInt16(0))
            directory.appendLittleEndian(UInt16(0))
            directory.appendLittleEndian(UInt16(0))
            directory.appendLittleEndian(UInt16(0))
            directory.appendLittleEndian(UInt32(0))
            directory.appendLittleEndian(offset)
            directory.append(nameData)
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.appendLittleEndian(UInt32(0x0605_4B50))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(entries.count))
        output.appendLittleEndian(UInt16(entries.count))
        output.appendLittleEndian(UInt32(directory.count))
        output.appendLittleEndian(directoryOffset)
        output.appendLittleEndian(UInt16(0))
        return output
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// 读出一个「存储方式」ZIP 的全部条目并逐条校验 CRC。
    ///
    /// 用于自检与排错：能读出来就说明文件结构合法、内容没被写坏。
    /// 遇到压缩条目或结构损坏时返回 `nil`。
    public static func parse(_ data: Data) -> [(name: String, data: Data)]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { return nil }

        var endOfDirectory = -1
        var cursor = bytes.count - 22
        while cursor >= 0 {
            if readUInt32(bytes, cursor) == 0x0605_4B50 {
                endOfDirectory = cursor
                break
            }
            cursor -= 1
        }
        guard endOfDirectory >= 0 else { return nil }

        let entryCount = Int(readUInt16(bytes, endOfDirectory + 10))
        var offset = Int(readUInt32(bytes, endOfDirectory + 16))
        var entries: [(name: String, data: Data)] = []
        entries.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard readUInt32(bytes, offset) == 0x0201_4B50 else { return nil }
            guard readUInt16(bytes, offset + 10) == 0 else { return nil }   // 仅支持存储方式
            let checksum = readUInt32(bytes, offset + 16)
            let size = Int(readUInt32(bytes, offset + 20))
            let nameLength = Int(readUInt16(bytes, offset + 28))
            let extraLength = Int(readUInt16(bytes, offset + 30))
            let commentLength = Int(readUInt16(bytes, offset + 32))
            let localOffset = Int(readUInt32(bytes, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else { return nil }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            guard readUInt32(bytes, localOffset) == 0x0403_4B50 else { return nil }
            let localNameLength = Int(readUInt16(bytes, localOffset + 26))
            let localExtraLength = Int(readUInt16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart >= 0, dataStart + size <= bytes.count else { return nil }

            let payload = Data(bytes[dataStart..<(dataStart + size)])
            guard crc32(payload) == checksum else { return nil }
            entries.append((name, payload))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
