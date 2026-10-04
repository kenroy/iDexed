import Foundation

/// Operator routing for one of the 32 DX7 algorithms, derived from msfa's bus-flag table
/// so the diagram can never disagree with what the engine actually plays.
public struct AlgorithmGraph: Sendable {
    public struct Edge: Hashable, Sendable {
        public let from: Int  // operator number 1…6
        public let to: Int
        public let isFeedback: Bool
    }

    /// Operator numbers (1…6) that feed the output.
    public let carriers: Set<Int>
    public let edges: [Edge]
    /// Row 0 is the top (furthest modulator); the bottom row holds carriers.
    public let rows: [Int: Int]
    /// Horizontal slot per operator, in units of one operator width.
    public let columns: [Int: Double]
    public let rowCount: Int
    public let width: Double

    // Same table as FmCore::algorithms in fm_core.cc; index 0 is OP6 (the first op processed).
    private static let table: [[UInt8]] = [
        [0xc1, 0x11, 0x11, 0x14, 0x01, 0x14], [0x01, 0x11, 0x11, 0x14, 0xc1, 0x14],
        [0xc1, 0x11, 0x14, 0x01, 0x11, 0x14], [0xc1, 0x11, 0x94, 0x01, 0x11, 0x14],
        [0xc1, 0x14, 0x01, 0x14, 0x01, 0x14], [0xc1, 0x94, 0x01, 0x14, 0x01, 0x14],
        [0xc1, 0x11, 0x05, 0x14, 0x01, 0x14], [0x01, 0x11, 0xc5, 0x14, 0x01, 0x14],
        [0x01, 0x11, 0x05, 0x14, 0xc1, 0x14], [0x01, 0x05, 0x14, 0xc1, 0x11, 0x14],
        [0xc1, 0x05, 0x14, 0x01, 0x11, 0x14], [0x01, 0x05, 0x05, 0x14, 0xc1, 0x14],
        [0xc1, 0x05, 0x05, 0x14, 0x01, 0x14], [0xc1, 0x05, 0x11, 0x14, 0x01, 0x14],
        [0x01, 0x05, 0x11, 0x14, 0xc1, 0x14], [0xc1, 0x11, 0x02, 0x25, 0x05, 0x14],
        [0x01, 0x11, 0x02, 0x25, 0xc5, 0x14], [0x01, 0x11, 0x11, 0xc5, 0x05, 0x14],
        [0xc1, 0x14, 0x14, 0x01, 0x11, 0x14], [0x01, 0x05, 0x14, 0xc1, 0x14, 0x14],
        [0x01, 0x14, 0x14, 0xc1, 0x14, 0x14], [0xc1, 0x14, 0x14, 0x14, 0x01, 0x14],
        [0xc1, 0x14, 0x14, 0x01, 0x14, 0x04], [0xc1, 0x14, 0x14, 0x14, 0x04, 0x04],
        [0xc1, 0x14, 0x14, 0x04, 0x04, 0x04], [0xc1, 0x05, 0x14, 0x01, 0x14, 0x04],
        [0x01, 0x05, 0x14, 0xc1, 0x14, 0x04], [0x04, 0xc1, 0x11, 0x14, 0x01, 0x14],
        [0xc1, 0x14, 0x01, 0x14, 0x04, 0x04], [0x04, 0xc1, 0x11, 0x14, 0x04, 0x04],
        [0xc1, 0x14, 0x04, 0x04, 0x04, 0x04], [0xc4, 0x04, 0x04, 0x04, 0x04, 0x04],
    ]

    public static let all: [AlgorithmGraph] = (0..<32).map { AlgorithmGraph(index: $0) }

    public init(index: Int) {
        let flags = Self.table[max(0, min(31, index))]
        var bus: [Int: Set<Int>] = [1: [], 2: []]
        var edges: [Edge] = []
        var carriers = Set<Int>()
        var fbIn: Int?, fbOut: Int?

        for i in 0..<6 {
            let f = flags[i]
            let op = 6 - i
            var inputs = Set<Int>()
            if f & 0x10 != 0 { inputs.formUnion(bus[1]!) }
            if f & 0x20 != 0 { inputs.formUnion(bus[2]!) }
            for src in inputs { edges.append(Edge(from: src, to: op, isFeedback: false)) }
            if f & 0x40 != 0 { fbIn = op }
            if f & 0x80 != 0 { fbOut = op }

            let outBus = Int(f & 3)
            let add = f & 4 != 0
            if outBus == 0 {
                carriers.insert(op)
            } else if add {
                bus[outBus, default: []].insert(op)
            } else {
                bus[outBus] = [op]
            }
        }
        if let a = fbIn, let b = fbOut { edges.append(Edge(from: b, to: a, isFeedback: true)) }

        // Layering: distance from the nearest carrier along modulation edges.
        let forward = edges.filter { !$0.isFeedback }
        var depth: [Int: Int] = [:]
        func d(_ op: Int) -> Int {
            if let v = depth[op] { return v }
            let outs = forward.filter { $0.from == op }.map { d($0.to) + 1 }
            let v = carriers.contains(op) && outs.isEmpty ? 0 : (outs.max() ?? 0)
            depth[op] = v
            return v
        }
        for op in 1...6 { _ = d(op) }
        let maxDepth = depth.values.max() ?? 0
        var rows: [Int: Int] = [:]
        for op in 1...6 { rows[op] = maxDepth - (depth[op] ?? 0) }

        // Columns: carriers evenly from the left, then each higher row sits above the mean of its targets.
        var cols: [Int: Double] = [:]
        let bottom = (1...6).filter { rows[$0] == maxDepth }.sorted()
        for (i, op) in bottom.enumerated() { cols[op] = Double(i) }
        for r in stride(from: maxDepth - 1, through: 0, by: -1) {
            let ops = (1...6).filter { rows[$0] == r }
            var desired: [(Int, Double)] = ops.map { op in
                let targets = forward.filter { $0.from == op }.compactMap { cols[$0.to] }
                return (op, targets.isEmpty ? 0 : targets.reduce(0, +) / Double(targets.count))
            }
            desired.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            var last = -Double.infinity
            for (op, x) in desired {
                let placed = max(x, last + 1)
                cols[op] = placed
                last = placed
            }
        }
        // Rows that are not the bottom row may contain carriers (e.g. op 1 in a stack); keep them as placed.
        let minX = cols.values.min() ?? 0
        for k in cols.keys { cols[k]! -= minX }

        self.carriers = carriers
        self.edges = edges
        self.rows = rows
        self.columns = cols
        self.rowCount = maxDepth + 1
        self.width = (cols.values.max() ?? 0) + 1
    }
}
