import dtef;

void assertEquals(T)(T actual, T expected)
{
        import std.conv : to;

        assert(actual == expected, "\nActual: " ~ actual.to!string ~ "\nExpected: " ~ expected
                        .to!string);
}

// Basic Main Line Processing
unittest
{
        LineData lineData = {};
        process("_D4main5sleepFNbNilZv	4	152406643	152403752", lineData);
        assertEquals(lineData.name, "nothrow @nogc void main.sleep(long)");
        assertEquals(lineData.time, 152_406_643L);
        assertEquals(lineData.callCount, 4);
}

// Basic Callee Line Processing
unittest
{
        import std.typecons : tuple;

        LineData lineData = {name: "_DMain"};
        process("	    1	_D4main5fast2FNbNiZv", lineData);
        assertEquals(lineData.name, "_DMain");
        assertEquals(lineData.time, 0L);
        assertEquals(lineData.callCount, 0);
        assertEquals(lineData.calledBy, []);
        assertEquals(lineData.calls, [
                tuple!("name", "count")("nothrow @nogc void main.fast2()", cast(uint) 1)
        ]);
}

// Full Entry Processing
unittest
{
        import std.typecons : tuple;

        LineData lineData = {};
        auto res1 = process("	    2	_D4main__T8fastSlowZQkFNbNiZv", lineData);
        auto res2 = process("_D4main4slowFNbNiZv	2	114157000	524", lineData);
        auto res3 = process("	    2	_D4main5sleepFNbNilZv", lineData);
        auto res4 = process("------------------", lineData);
        with (ProcessResult)
        {
                assertEquals([goOn, goOn, goOn, addLineData], [
                        res1, res2, res3, res4
                ]);
        }
        assertEquals(lineData.name, "nothrow @nogc void main.slow()");
        assertEquals(lineData.time, 114_157_000L);
        assertEquals(lineData.callCount, 2);
        assertEquals(lineData.calledBy, [
                "nothrow @nogc void main.fastSlow!().fastSlow()"
        ]);
        assertEquals(lineData.calls, [
                tuple!("name", "count")("nothrow @nogc void main.sleep(long)", cast(uint) 2)
        ]);
}

// Full File Processing
unittest
{
        import std.typecons : Tuple;
        import std.algorithm.iteration : splitter;
        import std.array : array;

        enum input = "------------------
	    4	_D4main5sleepFNbNilZv
_D4core4time__T3durVAyaa5_6d73656373ZQwFNaNbNiNflZSQBxQBv8Duration	4	2891	2544
	    4	_D4core4time__T7convertVAyaa5_6d73656373VQra6_686e73656373ZQBsFNaNbNiNflZl
------------------
	    4	_D4core4time__T3durVAyaa5_6d73656373ZQwFNaNbNiNflZSQBxQBv8Duration
_D4core4time__T7convertVAyaa5_6d73656373VQra6_686e73656373ZQBsFNaNbNiNflZl	4	347	347
------------------
_D4core8internal5array8equality__T8__equalsTaTaZQoFNaNbNiNeMxAaMxQeZb	0	315	315
------------------
	    2	_D4main5fast2FNbNiZv
	    1	_D4main__T8fastSlowZQkFNbNiZv
_D4main4fastFNbNiZv	3	38251798	1631
	    3	_D4main5sleepFNbNilZv
------------------
	    1	_D4main__T8fastSlowZQkFNbNiZv
_D4main4slowFNbNiZv	1	114157000	524
	    1	_D4main5sleepFNbNilZv
------------------
	    1	_Dmain
_D4main5fast2FNbNiZv	1	25983616	1874
	    2	_D4main4fastFNbNiZv
------------------
	    3	_D4main4fastFNbNiZv
	    1	_D4main4slowFNbNiZv
_D4main5sleepFNbNilZv	4	152406643	152403752
	    4	_D4core4time__T3durVAyaa5_6d73656373ZQwFNaNbNiNflZSQBxQBv8Duration
------------------
	    1	_Dmain
_D4main7nothingFNbNiZv	1	568	436
	    2	_D4main9doNothingFNbNiZv
------------------
	    2	_D4main7nothingFNbNiZv
_D4main9doNothingFNbNiZv	2	132	132
------------------
	    1	_Dmain
_D4main__T8fastSlowZQkFNbNiZv	1	126428865	1809
	    1	_D4main4fastFNbNiZv
	    1	_D4main4slowFNbNiZv
------------------
_Dmain	0	152415759	2710
	    1	_D4main5fast2FNbNiZv
	    1	_D4main__T8fastSlowZQkFNbNiZv
	    1	_D4main7nothingFNbNiZv

======== Timer frequency unknown, Times are in Megaticks ========
".splitter('\n').array;

        auto result = parseLines(input);

        assertEquals(result, [
                "nothrow @nogc void main.fast()": LineData("nothrow @nogc void main.fast()", [
                        "nothrow @nogc void main.fast2()",
                        "nothrow @nogc void main.fastSlow!().fastSlow()"
                ], [
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.sleep(long)", 3)
                ], 3, 38251798),
                "nothrow @nogc void main.nothing()": LineData("nothrow @nogc void main.nothing()", [
                        "_Dmain"
                ], [
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.doNothing()", 2)
                ], 1, 568),
                "pure nothrow @nogc @safe long core.time.convert!(\"msecs\", \"hnsecs\").convert(long)": LineData(
                        "pure nothrow @nogc @safe long core.time.convert!(\"msecs\", \"hnsecs\").convert(long)", [
                        "pure nothrow @nogc @safe core.time.Duration core.time.dur!(\"msecs\").dur(long)"
                ], [], 4, 347),
                "pure nothrow @nogc @trusted bool core.internal.array.equality.__equals!(char, char).__equals(scope const(char[]), scope const(char[]))": LineData(
                        "pure nothrow @nogc @trusted bool core.internal.array.equality.__equals!(char, char).__equals(scope const(char[]), scope const(char[]))", [
                ], [], 0, 315),
                "nothrow @nogc void main.fast2()": LineData("nothrow @nogc void main.fast2()", [
                        "_Dmain"
                ], [
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.fast()", 2)
                ], 1, 25983616),
                "nothrow @nogc void main.doNothing()": LineData("nothrow @nogc void main.doNothing()", [
                        "nothrow @nogc void main.nothing()"
                ], [], 2, 132),
                "pure nothrow @nogc @safe core.time.Duration core.time.dur!(\"msecs\").dur(long)": LineData(
                        "pure nothrow @nogc @safe core.time.Duration core.time.dur!(\"msecs\").dur(long)", [
                        "nothrow @nogc void main.sleep(long)"
                ], [
                        Tuple!(string, "name", uint, "count")("pure nothrow @nogc @safe long core.time.convert!(\"msecs\", \"hnsecs\").convert(long)", 4)
                ], 4, 2891),
                "_Dmain": LineData("_Dmain", [], [
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.fast2()", 1),
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.fastSlow!().fastSlow()", 1),
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.nothing()", 1)
                ], 0, 152415759),
                "nothrow @nogc void main.sleep(long)": LineData("nothrow @nogc void main.sleep(long)", [
                        "nothrow @nogc void main.fast()",
                        "nothrow @nogc void main.slow()"
                ], [
                        Tuple!(string, "name", uint, "count")(
                        "pure nothrow @nogc @safe core.time.Duration core.time.dur!(\"msecs\").dur(long)", 4)
                ], 4, 152406643),
                "nothrow @nogc void main.fastSlow!().fastSlow()": LineData(
                        "nothrow @nogc void main.fastSlow!().fastSlow()", [
                        "_Dmain"
                ], [
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.fast()", 1),
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.slow()", 1)
                ], 1, 126428865),
                "nothrow @nogc void main.slow()": LineData("nothrow @nogc void main.slow()", [
                        "nothrow @nogc void main.fastSlow!().fastSlow()"
                ], [
                        Tuple!(string, "name", uint, "count")("nothrow @nogc void main.sleep(long)", 1)
                ], 1, 114157000)
        ]);
}
