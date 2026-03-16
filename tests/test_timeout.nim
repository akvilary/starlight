import std/unittest
import ../src/starlight

# Handler with timeout and html pragma
handler fastHandler() {.html, timeout: 1000.}:
  return "Hello"

# Handler with timeout that will expire
handler slowHandler() {.html, timeout: 100.}:
  await sleepAsync(milliseconds(110))
  return "Too late"

# Handler with timeout only (no html/json)
handler rawTimeout() {.timeout: 2000.}:
  return answer("OK")

suite "timeout pragma":
  let ctx = newContext()

  test "fast handler completes within timeout":
    let res = waitFor fastHandler(ctx)
    check res.code == Http200
    check res.body == "Hello"

  test "slow handler times out with 408":
    let res = waitFor slowHandler(ctx)
    check res.code == Http408
    check res.body == "Request Timeout"

  test "timeout without html/json pragma":
    let res = waitFor rawTimeout(ctx)
    check res.code == Http200
    check res.body == "OK"
