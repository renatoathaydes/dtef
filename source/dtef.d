import std.stdio : File;

/// dtef output modes.
enum OutputMode
{
        json,
        text,
}

/// Callee information.
struct NameCount
{
        string name;
        uint count;
}

/// Information about a function call, including callees and callers.
struct FunCallInfo
{
        /// signature of the function.
        string name;
        /// who calls this function.
        string[] calledBy;
        /// which functions are called by this function.
        NameCount[] calls;
        /// how many times this function was called.
        long callCount;
        /// total time of execution of this function.
        long execTime;
        /// time of execution spent within function, rather than waiting on callees.
        long ownTime;

        this(ref return scope FunCallInfo info)
        {
                name = info.name;
                calledBy = info.calledBy.dup;
                calls = info.calls.dup;
                callCount = info.callCount;
                execTime = info.execTime;
                ownTime = info.ownTime;
        }

        long timePerCall() const pure => callCount == 0 || execTime == 0 ? 0 : execTime / callCount;

        FunCallInfo copyAndReset()
        {
                auto result = FunCallInfo(this);
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
        addInfo,
}

/// Parse a D trace log file.
FunCallInfo[string] parseFile(File file)
{
        return parseLines(file.byLine);
}

/// Parse a Range that gives each line as a `const(char)[]`.
FunCallInfo[string] parseLines(R)(R lines)
{
        import std.range : empty;

        string[] cb;
        NameCount[] ca;
        FunCallInfo[string] data;
        cb.reserve(32);
        ca.reserve(32);
        FunCallInfo info = {calledBy: cb, calls: ca};
        loop: foreach (const(char)[] line; lines)
        {
                auto res = process(line, info);
                final switch (res) with (ProcessResult)
                {
                case stop:
                        auto name = info.name;
                        if (!name.empty)
                        {
                                data[name] = info.copyAndReset;
                        }
                        break loop;
                case addInfo:
                        auto name = info.name;
                        data[name] = info.copyAndReset;
                        break;
                case goOn:
                        continue;
                }
        }
        return data;
}

void print(const ref FunCallInfo[string] data, OutputMode mode = OutputMode.json)
{
        import std.range : empty, repeat, take;
        import std.stdio : stdout, stderr;
        import std.json : JSONValue;

        bool first = true;
        auto json = JSONValue(["cat": "call", "ph": "X"]);
        json.object["pid"] = 0;
        json.object["tid"] = 0;

        void printJSON(const ref FunCallInfo info)
        {
                stdout.writeln(first ? "" : ",");
                first = false;
                json.object["ts"] = 0;
                json.object["name"] = info.name;
                json.object["dur"] = info.timePerCall();
                stdout.write(json);
        }

        void printText(const ref FunCallInfo info)
        {
                auto pctg = 100 * info.ownTime / info.execTime;
                stdout.writefln("%dx %s (%d us, %.2f%%)",
                        info.callCount, info.name, info.execTime, pctg);
                if (!info.calledBy.empty)
                {
                        stdout.writeln("    Called by:");
                        foreach (caller; info.calledBy)
                        {
                                stdout.writeln("        ", caller);
                        }
                }
                if (!info.calls.empty)
                {
                        stdout.writeln("    Calls:");
                        foreach (callee; info.calls)
                        {
                                if (auto calleeInfo = callee.name in data)
                                {
                                        auto calleeTime = callee.count * calleeInfo.timePerCall();
                                        pctg = 100 * calleeTime / info.execTime;
                                        stdout.writefln("        %dx %s (%d us, %.2f%%)",
                                                callee.count, callee.name, calleeTime, pctg);
                                }
                        }
                }
        }

        auto printer = mode == OutputMode.json ? &printJSON : &printText;

        if (mode == OutputMode.json)
                stdout.writeln("[");

        foreach (key, ref info; data)
        {
                printer(info);
        }

        if (mode == OutputMode.json)
                stdout.writeln("]");
}

ProcessResult process(in char[] line, ref FunCallInfo info)
{
        import std.range : empty;
        import std.algorithm.searching : startsWith;

        if (line.empty)
                return ProcessResult.stop;
        if (line.startsWith("-----"))
                with (ProcessResult)
                {
                        return info.name.empty ? goOn : addInfo;
                }
        info.addLine(line);
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

void addLine(ref FunCallInfo info, in char[] line)
{
        import std.algorithm.searching : startsWith;
        import std.range : back, empty;
        import std.stdio : stderr;

        // array that will hold a split line
        string[4] parts;

        // the file is encoded as Latin-2 so it can fail utf operations
        auto dline = decodeLatin(line);
        if (dline.startsWith("\t"))
        {
                // dline is a caller line if the name is still empty, or a callee line otherwise.
                if (info.name.empty)
                {
                        auto item = dline.parts(parts).back;
                        info.calledBy ~= computeName(item);
                }
                else
                {
                        auto items = dline[1 .. $].parts(parts);
                        if (items.length == 2)
                        {
                                auto name = computeName(items[1]);
                                auto count = items[0].toNumeric!uint(line);
                                info.calls ~= NameCount(name, count);
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
                        info.name = computeName(items[0]);
                        info.callCount = items[1].toNumeric!long(
                                line);
                        info.execTime = items[2].toNumeric!long(line);
                        info.ownTime = items[3].toNumeric!long(line);
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
