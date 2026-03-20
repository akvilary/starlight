import std/unittest
import ../src/starlight

suite "mkUrl — internal paths":
  test "static path with no params":
    check mkUrl("/about") == "/about"
    check mkUrl("/") == "/"

  test "single string param":
    check mkUrl("/users/{name}", name = "alice") == "/users/alice"

  test "single int param":
    check mkUrl("/posts/{id:int}", id = 42) == "/posts/42"

  test "single float param":
    check mkUrl("/price/{amount:float}", amount = 9.99) == "/price/9.99"

  test "single bool param":
    check mkUrl("/toggle/{active:bool}", active = true) == "/toggle/true"

  test "multiple path params":
    check mkUrl("/users/{name}/posts/{id:int}", name = "alice", id = 7) ==
      "/users/alice/posts/7"

  test "query params only":
    check mkUrl("/search", q = "nim") == "/search?q=nim"

  test "query param URL encoding":
    check mkUrl("/search", q = "hello world") == "/search?q=hello+world"

  test "multiple query params":
    check mkUrl("/search", q = "nim", page = 1) ==
      "/search?q=nim&page=1"

  test "mixed path and query params":
    check mkUrl("/users/{name}", name = "alice", tab = "posts") ==
      "/users/alice?tab=posts"

  test "variable references":
    let userName = "bob"
    let postId = 123
    check mkUrl("/users/{name}/posts/{id:int}", name = userName, id = postId) ==
      "/users/bob/posts/123"

  test "typed params with variables":
    let id = 99
    let price = 19.99
    let active = false
    check mkUrl("/posts/{id:int}", id = id) == "/posts/99"
    check mkUrl("/price/{amount:float}", amount = price) == "/price/19.99"
    check mkUrl("/toggle/{active:bool}", active = active) == "/toggle/false"

  test "const pattern":
    const usersPath = "/users/{name}"
    check mkUrl(usersPath, name = "alice") == "/users/alice"

  test "query param with special characters":
    check mkUrl("/search", q = "a&b=c") == "/search?q=a%26b%3Dc"

  test "empty path":
    check mkUrl("") == ""

suite "mkUrl — external URLs":
  test "full external URL without params":
    check mkUrl("https://example.com/about") == "https://example.com/about"

  test "external URL with path param":
    check mkUrl("https://api.example.com/users/{id:int}", id = 42) ==
      "https://api.example.com/users/42"

  test "external URL with query params":
    check mkUrl("https://google.com/search", q = "nim lang") ==
      "https://google.com/search?q=nim+lang"

  test "external URL with path and query params":
    check mkUrl("https://api.github.com/repos/{owner}/{repo}/issues",
      owner = "anthropics", repo = "claude-code", state = "open", page = 1) ==
      "https://api.github.com/repos/anthropics/claude-code/issues?state=open&page=1"
