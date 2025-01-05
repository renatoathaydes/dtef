@nogc:
nothrow:

void main() {
  fast2();
  fastSlow();
  nothing();
}

void fast2() {
  fast();
  fast();
}

void fastSlow()() {
  fast();
  slow();
}

void nothing() {
  doNothing();
  doNothing();
}

void slow() => sleep(100);

void fast() => sleep(10);

void doNothing() {}

void sleep(long ms) {
  import core.thread.osthread;
  import core.time : dur;
  Thread.sleep(dur!"msecs"(ms));
}
