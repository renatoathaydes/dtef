import std.typecons : Tuple;
import std.stdio : File;

alias NameCount = Tuple!(string, "name", uint, "count");

enum OutputMode
{
        json,
        text,
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

/// Parse a D trace log file.
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

void print(const ref LineData[string] data, OutputMode mode = OutputMode.json)
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

        void printText(const ref LineData lineData, long ts)
        {
                stdout.writefln("%dx %s (%d us)", lineData.callCount, lineData.name, lineData.time);
                if (!lineData.calledBy.empty)
                {
                        stdout.writeln("    Called by:");
                        foreach (caller; lineData.calledBy)
                        {
                                stdout.writeln("        ", caller);
                        }
                }
                if (!lineData.calls.empty)
                {
                        stdout.writeln("    Calls:");
                        foreach (callee; lineData.calls)
                        {
                                stdout.writeln("        ", callee);
                        }
                }
        }

        auto printer = mode == OutputMode.json ? &printJSON : &printText;

        if (mode == OutputMode.json)
                stdout.writeln("[");

        foreach (key, ref lineData; data)
        {
                printer(lineData, lineData.timePerCall());
        }

        if (mode == OutputMode.json)
                stdout.writeln("]");
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

private:

string computeName(string name)
{
        import std.demangle : demangle;
        import std.algorithm.searching : find, startsWith;
        import std.range.primitives : front, empty;
        import std.string : stripLeft;

        static const keywords = [
                "@nogc", "nothrow", "pure", "@trusted", "@system", "@safe"
        ];
        string prefixKeyword(string n) @nogc
        {
                auto keyword = keywords.find!((a) => n.startsWith(a));
                if (keyword.empty)
                {
                        return "";
                }
                return keyword.front;
        }

        auto n = demangle(name);
        string prefix;
        while (!(prefix = prefixKeyword(n)).empty)
        {
                n = n[prefix.length .. $].stripLeft;
        }
        return n;
}

version (unittest)
{
        import tested;

        @name("computeName")
        unittest
        {
                assert(computeName("foo") == "foo");
                assert(computeName("@nogc foo") == "foo");
                assert(computeName("@nogc nothrow foo") == "foo");
                assert(computeName("@nogc nothrow @system @trusted @safe foo") == "foo");
                assert(computeName("abc def") == "abc def");
        }
}

/// Break up the line into up to 4 parts using '\t' as separator.
/// Returns a slice backed by the provided array.
string[] parts(inout string line, out string[4] parts) pure @nogc
{
        import std.string : indexOf, count, strip;

        auto parts_count = line.count('\t') + 1;
        if (parts_count > 4)
                return parts[0 .. 0];
        size_t begin = 0;
        for (auto i = 0; i < parts_count; i++)
        {
                auto next_end = line.indexOf('\t', begin);
                parts[i] = line[begin .. next_end >= 0 ? next_end: $].strip;
                begin = next_end + 1;
        }
        return parts[0 .. parts_count];
}

void addLine(ref LineData lineData, in char[] line)
{
        import std.algorithm.searching : startsWith;
        import std.range : back, empty;
        import std.typecons : tuple;
        import std.stdio : stderr;

        // array that will hold a split line
        string[4] parts;

        // the file is encoded as Latin-2 so it can fail utf operations
        auto dline = decodeLatin(line);
        if (dline.startsWith("\t"))
        {
                // dline is a caller line if the name is still empty, or a callee line otherwise.
                if (lineData.name.empty)
                {
                        auto item = dline.parts(parts).back;
                        lineData.calledBy ~= computeName(item);
                }
                else
                {
                        auto items = dline[1 .. $].parts(parts);
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
                // dline is the actual call line, collect its name and time
                auto items = dline.parts(parts);
                if (items.length == 4)
                {
                        lineData.name = computeName(items[0]);
                        lineData.callCount = items[1].toNumeric!long(
                                line);
                        lineData.time = items[2].toNumeric!long(line);
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
