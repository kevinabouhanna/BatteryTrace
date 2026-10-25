// bttrace: Battery Trace's sampling layer without the UI.
//
// Prints exactly what the app would attribute, so the numbers can be checked
// against powermetrics, top and Activity Monitor before trusting the UI.
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let command = arguments.next() ?? "help"

switch command {
case "sources":
    SourcesCommand.run(&arguments)
case "sample":
    SampleCommand.run(&arguments)
case "stress":
    StressCommand.run(&arguments)
case "compare-top":
    CompareTopCommand.run(&arguments)
case "compare-powermetrics":
    ComparePowermetricsCommand.run(&arguments)
case "calibrate-display":
    CalibrateDisplayCommand.run(&arguments)
case "cost":
    CostCommand.run(&arguments)
case "totals":
    TotalsCommand.run(&arguments)
case "export":
    ExportCommand.run(&arguments)
default:
    print("""
    usage: bttrace <command> [options]

      sources                          what each data source found on this Mac
      sample [--interval 5] [--count 3] [--top 12] [--processes] [--json] [--no-billing]
                                       sample and attribute, like the app does
      cost [--interval 2] [--count 15] what sampling costs Battery Trace, per tick and per minute
      totals [--minutes 5]             minute-by-minute totals against the battery gauge
      export [--to DIR] [--days 7]     the app's history as two CSV files
      stress cpu [--threads N] [--seconds 30]
      stress gpu [--seconds 30]        load generators for validation
      compare-top [--interval 5] [--count 3]
                                       rank apps against top's POWER (Activity Monitor's Energy Impact)
      compare-powermetrics --ours FILE.jsonl --powermetrics FILE.plist
                                       compare a `sample --json` run with `powermetrics -f plist`
      calibrate-display [--settle 6]   fit the backlight power model (changes brightness, then restores it)
    """)
}

struct Arguments {
    private var items: [String]
    init(_ items: [String]) { self.items = items }

    mutating func next() -> String? { items.isEmpty ? nil : items.removeFirst() }

    mutating func flag(_ name: String) -> Bool {
        guard let index = items.firstIndex(of: name) else { return false }
        items.remove(at: index)
        return true
    }

    mutating func value(_ name: String) -> String? {
        guard let index = items.firstIndex(of: name), index + 1 < items.count else { return nil }
        let value = items[index + 1]
        items.removeSubrange(index...index + 1)
        return value
    }

    mutating func double(_ name: String, default fallback: Double) -> Double { value(name).flatMap(Double.init) ?? fallback }
    mutating func int(_ name: String, default fallback: Int) -> Int { value(name).flatMap(Int.init) ?? fallback }
}
