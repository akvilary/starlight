import std/unittest
import ../src/starlight

suite "urlAs — internal paths":
  test "static path with no params":
    check urlAs("/about") == "/about"
    check urlAs("/") == "/"

  test "single string param":
    check urlAs("/users/{name}", name = "alice") == "/users/alice"

  test "single int param":
    check urlAs("/posts/{id:int}", id = 42) == "/posts/42"

  test "single float param":
    check urlAs("/price/{amount:float}", amount = 9.99) == "/price/9.99"

  test "single bool param":
    check urlAs("/toggle/{active:bool}", active = true) == "/toggle/true"

  test "multiple path params":
    check urlAs("/users/{name}/posts/{id:int}", name = "alice", id = 7) ==
      "/users/alice/posts/7"

  test "query params only":
    check urlAs("/search", q = "nim") == "/search?q=nim"

  test "query param URL encoding":
    check urlAs("/search", q = "hello world") == "/search?q=hello+world"

  test "multiple query params":
    check urlAs("/search", q = "nim", page = 1) ==
      "/search?q=nim&page=1"

  test "mixed path and query params":
    check urlAs("/users/{name}", name = "alice", tab = "posts") ==
      "/users/alice?tab=posts"

  test "variable references":
    let userName = "bob"
    let postId = 123
    check urlAs("/users/{name}/posts/{id:int}", name = userName, id = postId) ==
      "/users/bob/posts/123"

  test "typed params with variables":
    let id = 99
    let price = 19.99
    let active = false
    check urlAs("/posts/{id:int}", id = id) == "/posts/99"
    check urlAs("/price/{amount:float}", amount = price) == "/price/19.99"
    check urlAs("/toggle/{active:bool}", active = active) == "/toggle/false"

  test "const pattern":
    const usersPath = "/users/{name}"
    check urlAs(usersPath, name = "alice") == "/users/alice"

  test "query param with special characters":
    check urlAs("/search", q = "a&b=c") == "/search?q=a%26b%3Dc"

  test "empty path":
    check urlAs("") == ""

suite "urlAs — external URLs":
  test "full external URL without params":
    check urlAs("https://example.com/about") == "https://example.com/about"

  test "external URL with path param":
    check urlAs("https://api.example.com/users/{id:int}", id = 42) ==
      "https://api.example.com/users/42"

  test "external URL with query params":
    check urlAs("https://google.com/search", q = "nim lang") ==
      "https://google.com/search?q=nim+lang"

  test "external URL with path and query params":
    check urlAs(
      "https://api.github.com/repos/{owner}/{repo}/issues",
      owner = "anthropics", repo = "claude-code", state = "open", page = 1,
    ) ==
      "https://api.github.com/repos/anthropics/claude-code/issues?state=open&page=1"

suite "urlAs — RelRef / AbsRef":
  test "RelRef prepends ./ to absolute path":
    check urlAs("/users/{name}", RelRef, name = "alice") == "./users/alice"

  test "RelRef with query params":
    check urlAs("/search", RelRef, q = "nim") == "./search?q=nim"

  test "AbsRef is the default":
    check urlAs("/users/{name}", AbsRef, name = "alice") == "/users/alice"

  test "RelRef with no params":
    check urlAs("/about", RelRef) == "./about"

  test "RelRef with multiple path params":
    check urlAs("/users/{name}/posts/{id:int}", RelRef, name = "bob", id = 7) ==
      "./users/bob/posts/7"
