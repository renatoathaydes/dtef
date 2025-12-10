import std.typecons : Tuple;
import std.stdio : File;
import tested;

alias NameCount = Tuple!(string, "name", uint, "count");

LineData[string] parseFile(File file)
{
        return parseLines(file.byLine);
}

/// Parse a Range that gives each line as a `const(char)[]`.
LineData[string] parseLines(R)(R lines)
{
        import std.range : empty;

        string[] cb;
        NameCount[] ca;
        LineData[string] data;
        cb.reserve(32);
        ca.reserve(32);
        LineData lineData = {calledBy: cb, calls: ca};
        loop: foreach (const(char)[] line; lines)
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
        return data;
}

struct LineData
{
        string name;
        string[] calledBy;
        NameCount[] calls;
        long callCount;
        long time;

        this(ref return scope LineData lineData)
        {
                name = lineData.name;
                calledBy = lineData.calledBy.dup;
                calls = lineData.calls.dup;
                callCount = lineData.callCount;
                time = lineData.time;
        }

        long timePerCall() const pure => callCount == 0 || time == 0 ? 0 : time / callCount;

        LineData copyAndReset()
        {
                auto result = LineData(this);
                name = "";
                calledBy.length = 0;
                calls.length = 0;
                return result;
        }

}

enum ProcessResult
{
        stop,
        goOn,
        addLineData,
}

ProcessResult process(in char[] line, ref LineData lineData)
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

void print(const ref LineData[string] data)
{
        import std.range : empty, repeat, take;
        import std.stdio : stdout, stderr;
        import std.json : JSONValue;

        bool first = true;
        auto json = JSONValue(["cat": "call", "ph": "X"]);
        json.object["pid"] = 0;
        json.object["tid"] = 0;

        void printJSON(const ref LineData lineData, long ts)
        {
                stdout.writeln(first ? "" : ",");
                first = false;
                json.object["ts"] = ts;
                json.object["name"] = lineData.name;
                json.object["dur"] = lineData.timePerCall();
                stdout.write(json);
        }

        void printAll(const ref LineData lineData, long ts)
        {
                printJSON(lineData, ts);
                auto callTs = ts;
                foreach (const ref call; lineData.calls)
                {
                        auto entry = call.name in data;
                        if (!entry)
                        {
                                stderr.writeln("WARNING: Orphan entry found: ", call.name);
                                continue;
                        }
                        auto tpc = entry.timePerCall();
                        for (auto i = 0; i < call.count; i++)
                        {
                                printAll(*entry, callTs);
                                callTs += tpc;
                        }
                }
        }

        // find the roots, then start printing events as calls are made
        foreach (ref entry; data)
        {
                if (entry.calledBy.empty)
                {
                        printAll(entry, 0);
                }
        }
}

string computeName(string name) {
  import std.demangle : demangle;
  import std.algorithm.searching : find, startsWith;
  import std.range.primitives : front, empty;
  import std.string : stripLeft;

  static const keywords = ["@nogc", "nothrow", "pure", "@trusted", "@system", "@safe"];
  string prefixKeyword(string n) @nogc {
    auto keyword = keywords.find!((a) => n.startsWith(a));
    if (keyword.empty) {
      return "";
    }
    return keyword.front;
  }
  auto n = demangle(name);
  string prefix;
  while (!(prefix = prefixKeyword(n)).empty) {
    n = n[prefix.length .. $].stripLeft;
  }
  return n;
}

@name("computeName")
unittest {
  assert(computeName("foo") == "foo");
  assert(computeName("@nogc foo") == "foo");
  assert(computeName("@nogc nothrow foo") == "foo");
  assert(computeName("@nogc nothrow @system @trusted @safe foo") == "foo");
  assert(computeName("abc def") == "abc def");
}

void addLine(ref LineData lineData, in char[] line)
{
        import std.algorithm.searching : startsWith, findSplit;
        import std.algorithm.iteration : filter, splitter, map;
        import std.array : array;
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
                        lineData.calledBy ~= computeName(item);
                }
                else
                {
                        auto items = dline[1 .. $].splitter('\t')
                                .map!(p => p.strip)
                                .filter!(p => !p.empty)
                                .array;
                        if (items.length == 2)
                        {
                                auto name = computeName(items[1]);
                                auto count = items[0].toNumeric!uint(line);
                                lineData.calls ~= tuple!("name", "count")(name, count);
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
                        lineData.name = computeName(parts[0]);
                        lineData.callCount = parts[1].toNumeric!long(
                                line);
                        lineData.time = parts[2].toNumeric!long(line);
                }
                else
                {
                        stderr.writeln("WARNING: Invalid function name line (not <name>\\t<count>\\t<total-time>\\t<own-time>): '", dline, "'");
                }
        }
}

string decodeLatin(in char[] line)
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

N toNumeric(N)(string value, in char[] line)
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

version(unittest) {
} else:

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
        import std.stdio : write, writeln, stderr;
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
                import std.stdio : stderr;

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
