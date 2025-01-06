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
        import std.stdio : File, write, writeln;
        import std.algorithm.iteration : map;
        import std.typecons : Tuple;
        import std.range : empty;

        string path;

        if (args.length == 2)
        {
                path = args[1];
        }
        else if (args.length > 2)
        {
                import std.stdio : stderr;

                stderr.writeln("ERROR: Usage - only one argument expected");
                return 1;
        }
        else
        {
                path = "trace.log";
        }

        string[] cb;
        Tuple!(string, uint)[] ca;
        LineData[string] data;
        cb.reserve(32);
        ca.reserve(32);
        LineData lineData = {calledBy: cb, calls: ca};
        auto file = File(path);
        loop: foreach (line; file.byLine)
        {
                auto res = process(line, lineData);
                final switch (res) with (ProcessResult)
                {
                case stop:
                        auto name = lineData.name;
                        if (!name.empty)
                        {
                                data[name] = lineData.copyAndReset;
                        }
                        break loop;
                case addLineData:
                        auto name = lineData.name;
                        data[name] = lineData.copyAndReset;
                        break;
                case goOn:
                        continue;
                }
        }
        write("[");
        print(data);
        writeln("]");
        return 0;
}

struct LineData
{
        import std.typecons : Tuple;

        string[] calledBy;
        Tuple!(string, uint)[] calls;
        string name;
        long callCount;
        long time;

        this(ref return scope LineData lineData)
        {
                calledBy = lineData.calledBy.dup;
                calls = lineData.calls.dup;
                name = lineData.name;
                callCount = lineData.callCount;
                time = lineData.time;
        }

        long timePerCall() => callCount == 0 || time == 0 ? 0 : time / callCount;

}

enum ProcessResult
{
        stop,
        goOn,
        addLineData,
}

LineData copyAndReset(ref LineData lineData)
{
        auto result = LineData(lineData);
        lineData.calledBy.length = 0;
        lineData.calls.length = 0;
        lineData.name = "";
        return result;
}

ProcessResult process(char[] line, ref LineData lineData)
{
        import std.range : empty;
        import std.algorithm.searching : startsWith;

        if (line.empty)
                return ProcessResult.stop;
        if (line.startsWith("-----"))
                with (ProcessResult)
                {
                        return lineData.name.empty ? goOn : addLineData;
                }
        lineData.addLine(line);
        return ProcessResult.goOn;
}

void print(ref LineData[string] data)
{
        import std.range : empty, repeat, take;
        import std.stdio : stdout, stderr;
        import std.json : JSONValue;
        import std.typecons : Tuple;

        bool first = true;
        long ts;
        auto json = JSONValue(["cat": "call", "ph": "X"]);
        json.object["pid"] = 0;
        json.object["tid"] = 0;

        void printJSON(LineData* lineData)
        {
                stdout.writeln(first ? "" : ",");
                first = false;
                json.object["ts"] = ts;
                json.object["name"] = lineData.name;
                json.object["dur"] = lineData.timePerCall();
                stdout.write(json);
        }

        void printAll(Tuple!(string, uint)[] calls)
        {
                foreach (ref call; calls)
                {
                        auto count = call[1];
                        auto entry = call[0] in data;
                        if (!entry)
                        {
                                stderr.writeln("WARNING: Orphan entry found: ", call[0]);
                                continue;
                        }
                        auto tpc = entry.timePerCall();
                        stderr.writeln("TPC: ", tpc, " for ", entry.name);
                        for (auto i = 0; i < count; i++)
                        {

                                printJSON(entry);
                                printAll(entry.calls);
                                ts += tpc;
                        }
                }
        }

        // find the roots, then start printing events as calls are made
        foreach (ref entry; data)
        {
                if (entry.calledBy.empty)
                {
                        stderr.writeln("ROOT: ", entry.name);
                        printJSON(&entry);
                        printAll(entry.calls);
                }
        }
}

void addLine(ref LineData lineData, char[] line)
{
        import std.algorithm.searching : startsWith, findSplit;
        import std.algorithm.iteration : filter, splitter, map;
        import std.array : array;
        import std.demangle : demangle;
        import std.range : back, empty;
        import std.string : strip;
        import std.typecons : tuple;
        import std.stdio : stderr;

        // the file is encoded as Latin-2 so it can fail utf operations
        auto dline = decodeLatin(line);
        if (dline.startsWith("\t"))
        {
                if (lineData.name.empty)
                {
                        auto item = dline[1 .. $].splitter('\t').back;
                        lineData.calledBy ~= demangle(item);
                }
                else
                {
                        auto items = dline[1 .. $].splitter('\t')
                                .map!(p => p.strip)
                                .filter!(p => !p.empty)
                                .array;
                        if (items.length == 2)
                        {
                                lineData.calls ~= tuple(demangle(items[1]), items[0].toNumeric!uint(
                                                line));
                        }
                        else
                        {
                                stderr.writeln("WARNING: Callee line invalid (not <count>\\t<name>...): '", dline, "'");
                        }
                }
        }
        else
        {
                auto parts = dline.splitter('\t')
                        .map!(p => p.strip)
                        .array;
                if (parts.length == 4)
                {
                        lineData.name = demangle(parts[0]);
                        lineData.callCount = parts[1].toNumeric!long(line);
                        lineData.time = parts[2].toNumeric!long(line);
                }
                else
                {
                        stderr.writeln("WARNING: Invalid function name line (not <name>\\t<count>\\t<total-time>\\t<own-time>): '", dline, "'");
                }
        }
}

string decodeLatin(char[] line)
{
        import std.encoding : EncodingSchemeLatin2;
        import std.conv : to;

        dchar[] result;
        result.reserve(line.length);
        scope e = new EncodingSchemeLatin2();
        auto bytes = cast(const(ubyte)[]) line;
        while (bytes.length > 0)
        {
                auto d = e.decode(bytes);
                result ~= d;
        }
        return result.to!string;
}

N toNumeric(N)(string value, char[] line)
{
        import std.conv : to;
        import std.string : isNumeric;
        import std.stdio : stderr;

        if (value.isNumeric)
        {
                return value.to!N;
        }
        else
        {
                stderr.writeln("ERROR: data not numeric in '", line, "'");
        }
        return 0;
}
