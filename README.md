# dtef

Utility to converts DMD's `-profile` text format to [Google Trace Event Format](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/edit?tab=t.0).

## Usage

Compile your code using DMD's `-profile` flag. For example:

```shell
dmd -of=dtef -profile source/*.d
```

Or if using Dub:

```shell
dub build --build=profile
```

Now, runnig your program will produce a file called `trace.log`. That is the input for `dtef`.

To generate a profiler report, run `dtef` in the same working directory as `trace.log`, or provide the full path to that,
piping the output to the file you wish to use:

```shell
# assumes trace.log in the working directory
dtef > profile.json

# specify the path to trace.log
dtef path/to/trace.log > profile.json
```

## Output modes

### JSON

By default, the output is a JSON array which can be visualized by, for example, https://www.speedscope.app and https://ui.perfetto.dev.

### Text

Instead of producing a JSON file, you can also use a simpler, readable text format:

```
dtef -m text
```

Example (running [main.d](test/main.d)):

```shell
▶ ./dtef -m text test/trace.log 
0x _Dmain (152415759 us, 0.00%)
    Calls:
        1x void main.fast2() (25983616 us, 17.00%)
        1x void main.fastSlow!().fastSlow() (126428865 us, 82.00%)
        1x void main.nothing() (568 us, 0.00%)
2x void main.doNothing() (132 us, 100.00%)
    Called by:
        void main.nothing()
1x void main.slow() (114157000 us, 0.00%)
    Called by:
        void main.fastSlow!().fastSlow()
    Calls:
        1x void main.sleep(long) (38101660 us, 33.00%)
0x bool core.internal.array.equality.__equals!(char, char).__equals(scope const(char[]), scope const(char[])) (315 us, 100.00%)
3x void main.fast() (38251798 us, 0.00%)
    Called by:
        void main.fast2()
        void main.fastSlow!().fastSlow()
    Calls:
        3x void main.sleep(long) (114304980 us, 298.00%)
1x void main.fast2() (25983616 us, 0.00%)
    Called by:
        _Dmain
    Calls:
        2x void main.fast() (25501198 us, 98.00%)
4x long core.time.convert!("msecs", "hnsecs").convert(long) (347 us, 100.00%)
    Called by:
        core.time.Duration core.time.dur!("msecs").dur(long)
4x core.time.Duration core.time.dur!("msecs").dur(long) (2891 us, 87.00%)
    Called by:
        void main.sleep(long)
    Calls:
        4x long core.time.convert!("msecs", "hnsecs").convert(long) (344 us, 11.00%)
4x void main.sleep(long) (152406643 us, 99.00%)
    Called by:
        void main.fast()
        void main.slow()
    Calls:
        4x core.time.Duration core.time.dur!("msecs").dur(long) (2888 us, 0.00%)
1x void main.fastSlow!().fastSlow() (126428865 us, 0.00%)
    Called by:
        _Dmain
    Calls:
        1x void main.fast() (12750599 us, 10.00%)
        1x void main.slow() (114157000 us, 90.00%)
1x void main.nothing() (568 us, 76.00%)
    Called by:
        _Dmain
    Calls:
        2x void main.doNothing() (132 us, 23.00%)
```

Function `_Dmain` (i.e. D's `main`) is usually printed first and allows checking which functions are called and how much time is spent on each of them.

In this example, we see that 82% of the time was spent on `void main.fastSlow!().fastSlow()`.
If we search for that function's entry, we see that `90%` of its time was spent on `void main.slow()`, which just calls `void main.sleep(long)`.
Because the times shown are averages, in this case it seems like only `33%` of `void main.slow()` was spent on `sleep`, and there's nothing else accounting
for the rest. See the Limitations section below for more details about this sort of problem.

The percentage shown next to each function is how much of the time was spent on its own body, excluding other functions it called.
For example, in the following entry:

```shell
1x void main.nothing() (568 us, 76.00%)
    Called by:
        _Dmain
    Calls:
        2x void main.doNothing() (132 us, 23.00%)
```

We see that `void main.nothing()` spent `76%` of its time in its own body, and `23%` on the 2 calls it made to `void main.doNothing()`.

## Limitations

As the example above shows, there's some apparent inconsistencies that can be explained by the way the DMD profiler works.

First of all, even though the reported amount of time spent on each function is reliable, it is not really possible to know how much time was spent on each individual invocation, especially when the function may be called from many functions with different arguments which impact its running time.

Hence, while we can trust that `void main.fast2()` used `25983616 us` of the total running time, it is only an estimate that it used up `17%` of `_Dmain`'s total time.
Because that was the only invocation of this function, it happens to be actually quite accurate in this particular case.

On the other hand, the example program calls `sleep` with two very different values from the `slow` and `fast` functions (`100` and `10`, respectively).
That makes the reported share of time used by `sleep` look quite off: it was reported as taking only `33%` of `main.slow()`, but `298%` of `main.fast()`!

> Any function that varies widely in running time depending on its arguments will cause this issue.

In reality, because `sleep` is the only function called by both `main.slow()` and `main.fast()`, `sleep` should take 100% of either's running time.

When functions's running time does not vary much, their reported share of the running time of other functions become much more accurate.
For example, the `fastSlow` function calls `fast()` once, and then `slow()` once, so we expect that it should spend
around 90% of its time on `slow()` and the rest on `fast()`.

And that's exactly what is reported:

```shell
1x void main.fastSlow!().fastSlow() (126428865 us, 0.00%)
    Called by:
        _Dmain
    Calls:
        1x void main.fast() (12750599 us, 10.00%)
        1x void main.slow() (114157000 us, 90.00%)
```
