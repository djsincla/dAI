#!/usr/bin/env python3
"""
Generate a synthetic Swift package as E2's repeatable interactive workload.

Using a generated package rather than a real project matters: build time has to
be stable across runs and reproducible on any node, otherwise the contention
delta we're measuring is buried in variance from someone's dirty derived data.

The generated code is deliberately type-inference heavy - generics, protocol
conformances, and chained collection operations - because that is what makes
real Swift builds slow, and it is CPU and memory-bandwidth bound, which is the
resource MLX inference actually contends with on unified memory.
"""

import argparse
import pathlib
import shutil

PACKAGE_SWIFT = """// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "E2Workload",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "E2Workload", path: "Sources/E2Workload")
    ]
)
"""

MODULE_TEMPLATE = """import Foundation

// Module {n} - generic and protocol-heavy by design so the type checker, not
// codegen, dominates build time.

protocol Transformable{n} {{
    associatedtype Output
    func transform() -> Output
}}

struct Record{n}<Value: Numeric & Comparable>: Transformable{n} {{
    let id: Int
    let label: String
    let values: [Value]

    func transform() -> [Value] {{
        values.enumerated()
            .filter {{ $0.offset % 2 == 0 }}
            .map {{ $0.element }}
            .sorted(by: {{ $0 < $1 }})
    }}

    func summarize() -> (count: Int, label: String) {{
        (values.count, label.uppercased())
    }}
}}

extension Record{n} where Value == Double {{
    var mean: Double {{
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }}
}}

func combine{n}<T: Transformable{n}, U: Transformable{n}>(
    _ lhs: T, _ rhs: U
) -> (T.Output, U.Output) {{
    (lhs.transform(), rhs.transform())
}}

func pipeline{n}(_ input: [Int]) -> [String] {{
    input
        .map {{ Record{n}(id: $0, label: "item-\\($0)", values: [Double($0), Double($0) * 1.5]) }}
        .filter {{ $0.mean > 0 }}
        .sorted {{ $0.mean < $1.mean }}
        .map {{ "\\($0.id):\\($0.summarize().label):\\($0.mean)" }}
}}

enum Category{n}: String, CaseIterable {{
    case alpha, beta, gamma, delta

    var weight: Double {{
        switch self {{
        case .alpha: return 1.0
        case .beta: return 2.5
        case .gamma: return 3.75
        case .delta: return 4.125
        }}
    }}
}}

func categorize{n}(_ values: [Double]) -> [Category{n}: [Double]] {{
    Dictionary(grouping: values) {{ value in
        Category{n}.allCases[Int(abs(value)) % Category{n}.allCases.count]
    }}
}}
"""

MAIN_TEMPLATE = """import Foundation

// Touch every module so nothing is dead-stripped before it is type-checked.
var total = 0
{calls}
print("E2Workload checksum: \\(total)")
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--modules", type=int, default=60,
                    help="module count; tune for a ~30-60s clean build")
    ap.add_argument("--out", default=str(pathlib.Path(__file__).parent / "workload"))
    args = ap.parse_args()

    root = pathlib.Path(args.out)
    if root.exists():
        shutil.rmtree(root)
    src = root / "Sources" / "E2Workload"
    src.mkdir(parents=True)

    (root / "Package.swift").write_text(PACKAGE_SWIFT)
    for n in range(args.modules):
        (src / f"Module{n}.swift").write_text(MODULE_TEMPLATE.format(n=n))

    calls = "\n".join(
        f'total += pipeline{n}([{n}, {n + 1}, {n + 2}]).count + categorize{n}([Double({n})]).count'
        for n in range(args.modules)
    )
    (src / "main.swift").write_text(MAIN_TEMPLATE.format(calls=calls))

    print(f"Generated {args.modules}-module package at {root}")
    print("Time a clean build with:  python3 run_e2.py --calibrate")


if __name__ == "__main__":
    main()
