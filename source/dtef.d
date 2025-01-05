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
        string name;
        Tuple!(string, uint)[] calls;
        long time;

        this(ref return scope LineData lineData)
        {
                calledBy = lineData.calledBy.dup;
                calls = lineData.calls.dup;
                name = lineData.name;
                time = lineData.time;
        }
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
        import std.range : empty, back, repeat, take;
        import std.stdio : stdout;
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
                json.object["dur"] = lineData.time;
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
                                import std.stdio : stderr;

                                stderr.writeln("WARNING: Orphan entry found: ", call[0]);
                                continue;
                        }
                        foreach (_; repeat(true).take(count))
                        {
                                auto tsAfter = ts + entry.time;
                                printJSON(entry);
                                printAll(entry.calls);
                                ts = tsAfter;
                        }
                }
        }

        // find the roots, then start printing events as calls are made
        foreach (ref entry; data)
        {
                if (entry.calledBy.empty)
                {
                        import std.stdio;

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
        import std.conv : to;
        import std.demangle : demangle;
        import std.range : take, takeOne, front, back, empty, save;
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
                                .take(2);
                        auto count = items.consumeOne;
                        auto text = items.consumeOne;
                        if (count !is null && text !is null)
                        {
                                lineData.calls ~= tuple(demangle(text), count.to!uint);
                        }
                        else
                        {
                                stderr.writeln("WARNING: Callee line invalid (not <count>\\t<name>...): '", dline, "'");
                        }
                }
        }
        else
        {
                auto parts = dline.findSplit("\t");
                if (!parts[1].empty)
                {
                        lineData.name = demangle(parts[0]);
                        lineData.time = findTime(parts[2]);
                }
                else
                {
                        stderr.writeln("WARNING: Invalid function name line (not <name>\\t<time>): '", dline, "'");
                }
        }
}

auto consumeOne(T)(ref T range)
{
        if (!range.empty)
        {
                scope (exit)
                        range.popFront;
                return range.front;
        }
        return null;
}

string decodeLatin(char[] line)
{
        import std.encoding;
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

long findTime(string line)
{
        import std.conv : to;
        import std.string : isNumeric;
        import std.algorithm.iteration : splitter;
        import std.range : dropBackOne, back;

        auto item = line.splitter('\t').dropBackOne.back;
        if (item.isNumeric)
        {
                return item.to!long;
        }
        else
        {
                import std.stdio : stderr;

                stderr.writeln("ERROR: time data not numeric in '", line, "'");
        }
        return 0;
}
