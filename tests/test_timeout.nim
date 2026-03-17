import std/unittest
import ../src/starlight

handler fastHandler() {.html.}:
  return "Hello"

handler slowHandler() {.html.}:
  await sleepAsync(milliseconds(110))
  return "Too late"

handler rawHandler():
  return answer("OK")

suite "withTimeout middleware":
  let ctx = newContext()

  test "fast handler completes within timeout":
    let chain = buildChain(fastHandler, @[withTimeout(1000)])
    let res = waitFor chain(ctx)
    check res.code == Http200
    check res.body == "Hello"

  test "slow handler times out with 408":
    let chain = buildChain(slowHandler, @[withTimeout(100)])
    let res = waitFor chain(ctx)
    check res.code == Http408
    check res.body == "Request Timeout"

  test "timeout with raw handler":
    let chain = buildChain(rawHandler, @[withTimeout(2000)])
    let res = waitFor chain(ctx)
    check res.code == Http200
    check res.body == "OK"
