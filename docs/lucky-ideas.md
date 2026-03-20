# Ideas from Lucky Framework for Starlight

Analysis of Lucky (Crystal) features that could strengthen Starlight. Ordered by impact and fit.

---

## Already Implemented

| Lucky Feature | Starlight Equivalent |
|---|---|
| Type-safe link generation | `urlFor(route, ...)` / `urlAs(pattern, ...)` |
| `needs` — typed view dependencies | Layout parameters: `layout Page(user: User, posts: seq[Post])` |
| `continue` vs response in pipes | `next(ctx)` in middleware — explicit call or skip |
| Compile-time HTML DSL | `layout` macro with static/dynamic splitting |

---

## High Priority

### 1. Typed Query Parameters

**Lucky:** declares query params with types and defaults inside actions:
```crystal
param page : Int32 = 1
param filter : String?
```
Unsupported types or missing required params return 422 automatically.

**Starlight today:** `ctx.getQuery("page", "1")` — always strings, manual parsing.

**Proposal:** extend `handler` macro to parse query params:
```nim
handler listUsers(ctx: Context, page: int = 1, filter: string = "") {.html.}:
  # page and filter parsed from ?page=2&filter=active
  # type mismatch → 422 Unprocessable Entity
```

The `handler` macro already parses path params from the signature. Query params are the natural next step — same mechanism, different source.

**Effort:** Medium. Extend `generateHandlerWrapper` to check query string for params not found in the path pattern.

---

### 2. Content Negotiation (`accepted_formats`)

**Lucky:** actions declare which response formats they accept:
```crystal
accepted_formats [:html, :json], default: :html
```
Unsupported `Accept` header → automatic 406 Not Acceptable.

**Starlight today:** handlers manually check headers or just return one format.

**Proposal:** middleware or handler pragma:
```nim
handler getUser(ctx: Context, name: string) {.html, json.}:
  if ctx.wantsJson:
    return answerJson(%*{"name": name})
  return UserProfile(name=name)
```

Or as middleware:
```nim
router.use(withFormats(@["html", "json"]))
```

**Effort:** Low. A `withFormats` middleware is ~20 lines. A pragma-based approach needs handler macro changes.

---

## Medium Priority

### 4. Compile-Time Response Completeness Check

**Lucky:** every code branch in an action must return a response, or compilation fails:
```
MyAction returned Lucky::Response | Nil, but it must return Lucky::Response.
```

**Starlight today:** Nim's `async` proc checks return types, but allows branches without explicit returns (returns default empty Response).

**Proposal:** add a `handler` macro warning/error when `if`/`case` branches don't all contain `return`. This would catch common mistakes like:
```nim
handler getUser(ctx: Context, name: string) {.html.}:
  if name == "admin":
    return AdminPage()
  # forgot to return for non-admin → empty 200
```

**Effort:** Medium. Requires AST walking in the handler macro to check branch coverage.

---

### 5. Method-Overload Error Handling

**Lucky:** error handlers dispatch by exception type:
```crystal
def render(error : NotFoundError) → 404 page
def render(error : AuthError) → 401 page
def render(error : Exception) → 500 fallback
```

**Starlight today:** `router.onError(Http404, handler)` — dispatch by HTTP code only.

**Proposal:** add `router.onException` that dispatches by exception type:
```nim
router.onException(NotFoundError, notFoundHandler)
router.onException(AuthError, unauthorizedHandler)
# Falls through to onError(Http500) for unknown exceptions
```

**Effort:** Medium. Needs a `Table[string, HandlerProc]` keyed by exception type name, matched in the dispatch catch block.

---

### 6. Pagination

**Lucky:** built-in `paginate` method on actions:
```crystal
pages, users = paginate(UserQuery.new)
```
Returns paginator + filtered query. Includes HTML components for page links.

**Starlight today:** nothing built-in.

**Proposal:** a `paginate` helper that works with any seq:
```nim
let (page, items) = paginate(allUsers, ctx.getQuery("page", "1"), perPage=20)
# page: Paginator object with .current, .total, .hasNext, .hasPrev
# items: seq slice for current page

layout PaginationNav(page: Paginator) {.buf.}:
  Nav:
    if page.hasPrev:
      A(href=urlAs("/users", page = page.current - 1)): "Prev"
    for p in page.series:
      A(href=urlAs("/users", page = p)): $p
    if page.hasNext:
      A(href=urlAs("/users", page = page.current + 1)): "Next"
```

**Effort:** Low-Medium. Paginator type + helper proc + optional layout component.

---

## Low Priority

### 7. CSRF Protection

**Lucky:** automatic CSRF tokens in forms for browser actions.

**Proposal:** a `csrfMiddleware` + `csrfToken(ctx)` helper that:
- Generates a token per session
- Validates on POST/PUT/PATCH/DELETE
- `csrfField(ctx)` returns a hidden input for layouts

**Effort:** Medium. Depends on sessions (not yet implemented).

---

### 8. Flash Messages

**Lucky:** `flash.success = "Created!"` persists a message across a redirect.

**Proposal:** tied to sessions. Once cookies/sessions are implemented:
```nim
ctx.flash("success", "User created!")
return redirect("/users")

# In layout:
if ctx.hasFlash("success"):
  Div(class="alert"): ctx.getFlash("success")
```

**Effort:** Low once sessions exist.

---

### 9. Memoization

**Lucky:** `memoize` macro caches expensive computations within a single request:
```crystal
memoize def current_user : User
  UserQuery.find(user_id)
end
```

**Proposal:** a `once` template or similar:
```nim
handler dashboard(ctx: Context) {.html.}:
  let user = ctx.memoize("user"): findUser(ctx.userId)
  let stats = ctx.memoize("stats"): computeStats(user)
  return DashboardPage(user=user, stats=stats)
```

**Effort:** Low. Store results in `ctx` as a `Table[string, pointer]` or similar.

---

## Not a Fit for Starlight

| Lucky Feature | Why Skip |
|---|---|
| One action per class | Overkill for Nim; route groups are more compact and idiomatic |
| ORM (Avram) | Out of scope; better to integrate with existing Nim ORMs (norm, allographer) |
| `permit_columns` mass assignment protection | ORM-specific, not applicable without ORM |
| Schema Enforcer | ORM-specific |
| Asset pipeline (Webpack/Laravel Mix) | Starlight CDN proxy is simpler and more flexible |
| Auth scaffolding | Too opinionated for a micro-framework; should be a separate package |
| `dont_report` error suppression | Minor feature, easy to add if needed |

---

## Recommended Roadmap

**Next up (builds on today's work):**
1. Typed query parameters in `handler` macro
2. `withFormats` content negotiation middleware

**After cookies/sessions land:**
4. CSRF protection middleware
5. Flash messages

**Nice to have:**
6. Pagination helper
7. Response completeness check in handler macro
8. Exception-based error dispatch
