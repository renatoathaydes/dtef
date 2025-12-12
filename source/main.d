import dtef;

immutable dtefHelp = "dtef is a utility to parse D's trace.log files.
To generate a trace file, use the -profile option when compiling D code, then run the binary.

Usage:
    dtef [options...] [file...]

If no file is provided, dtef will parse the 'trace.log' file in the working directory.

Options:";

/// Terminal app for converting D's log.trace (generated using dmd -profile)
/// to the Google Trace Event Format (https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/edit?tab=t.0).
///
/// Files in the TEF format may be visualized using chrome://tracing or https://www.speedscope.app/ for example.
///
/// Usage:
///   dtef [<trace.log file>]
/// If not given, parses trace.log in the working directory.
int main(string[] args)
{
        import std.getopt;
        import std.stdio : File, write, writeln, stderr;
        import std.process : environment;
        import std.range : empty;

        bool isDebug;
        OutputMode outputMode;
        GetoptResult optResult;

        try
        {
                optResult = getopt(args,
                        "mode|m", "output mode (json | text)", &outputMode,
                        "debug|d", "whether to enable debug output", &isDebug);
        }
        catch (GetOptException e)
        {
                writeln("ERROR: ", e.msg);
                defaultGetoptPrinter(dtefHelp, optResult.options);
                return 1;
        }

        if (optResult.helpWanted)
        {
                defaultGetoptPrinter(dtefHelp, optResult.options);
                return 0;
        }

        auto files = args[1 .. $];

        if (files.empty)
        {
                files = ["trace.log"];
        }

        foreach (path; files)
        {
                LineData[string] data = void;
                {
                        auto file = File(path);
                        data = parseFile(file);
                }

                if (isDebug)
                {
                        foreach (entry; data)
                                stderr.writeln(entry);
                }
                print(data, outputMode);
        }

        return 0;
}
