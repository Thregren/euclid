/// 有界工作队列使用的摊销 O(1) FIFO；弹出时立即释放元素，批量压缩已消费的前缀。
package struct FIFOQueue<Element> {
    private var storage: [Element?] = []
    private var head = 0

    package var count: Int { storage.count - head }
    package var isEmpty: Bool { count == 0 }
    package var elements: [Element] { storage[head...].compactMap { $0 } }

    package init() {}

    package mutating func append(_ element: Element) { storage.append(element) }

    package mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        storage[head] = nil
        head += 1
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head >= storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    package mutating func removeAll(where predicate: (Element) -> Bool) {
        storage = storage[head...].compactMap { $0 }.filter { !predicate($0) }.map { Optional($0) }
        head = 0
    }
}
