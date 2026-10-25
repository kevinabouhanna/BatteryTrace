import Darwin
import HelperServer

// Battery Trace's optional root helper. Everything it does is in
// HelperServer (BatteryTraceKit), where it is tested; see its header.
exit(HelperMain.run(CommandLine.arguments))
