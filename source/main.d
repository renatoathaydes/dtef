import dtef;

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
        import std.stdio : File, write, writeln, stderr;
        import std.process : environment;
        import std.range : empty;

        string path;
        bool isDebug = !environment.get("DEBUG", "").empty;

        if (args.length == 2)
        {
                path = args[1];
        }
        else if (args.length > 2)
        {
                stderr.writeln("ERROR: Usage - only one argument expected");
                return 1;
        }
        else
        {
                path = "trace.log";
        }

        LineData[string] data = void;
        {
                auto file = File(path);
                data = parseFile(file);
        }

        write("[");
        if (isDebug)
        {
                foreach (entry; data)
                        stderr.writeln(entry);
        }
        print(data);
        writeln("]");

        return 0;
}
