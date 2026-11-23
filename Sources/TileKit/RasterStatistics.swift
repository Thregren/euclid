import Accelerate
import Foundation

/// 在固定大小的工作缓冲中使用 ARM 向量运算；保留 Double 累加与非有限值过滤。
package enum RasterStatistics {
    package static func compute(_ values: [Float]) -> DEMAnalysis.Statistics {
        guard values.count >= 4096 else { return scalar(values) }
        var workspace = [Double](repeating: 0, count: 4096)
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        values.withUnsafeBufferPointer { input in
            workspace.withUnsafeMutableBufferPointer { output in
                guard let source = input.baseAddress, let target = output.baseAddress else { return }
                var offset = 0
                while offset < input.count {
                    let length = min(output.count, input.count - offset)
                    vDSP_vspdp(source + offset, 1, target, 1, vDSP_Length(length))
                    var valid = 0
                    for index in 0..<length where target[index].isFinite {
                        target[valid] = target[index]
                        valid += 1
                    }
                    if valid > 0 {
                        var low = 0.0, high = 0.0, subtotal = 0.0
                        vDSP_minvD(target, 1, &low, vDSP_Length(valid))
                        vDSP_maxvD(target, 1, &high, vDSP_Length(valid))
                        vDSP_sveD(target, 1, &subtotal, vDSP_Length(valid))
                        minimum = min(minimum, low)
                        maximum = max(maximum, high)
                        sum += subtotal
                        count += valid
                    }
                    offset += length
                }
            }
        }
        return result(count: count, minimum: minimum, maximum: maximum, sum: sum)
    }

    package static func scalar(_ values: [Float]) -> DEMAnalysis.Statistics {
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        var sum = 0.0
        var count = 0
        for value in values where value.isFinite {
            let number = Double(value)
            low = min(low, number)
            high = max(high, number)
            sum += number
            count += 1
        }
        return result(count: count, minimum: low, maximum: high, sum: sum)
    }

    private static func result(count: Int, minimum: Double, maximum: Double, sum: Double) -> DEMAnalysis.Statistics {
        DEMAnalysis.Statistics(validCount: count,
                               minimum: count > 0 ? minimum : .nan,
                               maximum: count > 0 ? maximum : .nan,
                               mean: count > 0 ? sum / Double(count) : .nan)
    }
}
