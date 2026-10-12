# Forum Fortress development dependency backport

This is a local MIT-licensed backport of the published `braces@3.0.3` npm
archive, not an upstream release. Its upstream archive integrity is:

`sha512-yQbXgO/OSZVD2IsiLlro+7Hf6Q18EJrKSEsdoMzKePKXct3gvD8oLcOQdIzGupr5Fj+EDe8gO/lxc1BzfMpxvA==`

The upstream license and source attribution remain in `LICENSE`, `README.md`
and `package.json`. The local package version is `3.0.3-forumfortress.1`.
It is used only by Discourse's development lint tools; no runtime plugin code
imports it. The local package is not published to npm.

The backport addresses [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)
while no patched upstream version is available. A fixed 128-level bound covers
parsed braces and parentheses, compiler/stringifier/expander AST traversals,
parent-chain walks and recursive expansion/flattening of arrays. Caller options
cannot increase or disable the bound. Excessive structures, including cyclic
ASTs and arrays, fail with a controlled `SyntaxError` whose code is
`ERR_BRACES_MAX_DEPTH`, before exhausting the JavaScript call stack.
Caller-provided ASTs also require string values and array child lists, preventing
malformed values from bypassing the bounds through implicit array coercion.

The ordinary npm advisory feed does not describe this local backport, so a clean
pnpm audit is not evidence of its safety. The fixed private CI harness sets
`FF_PRIVATE_PLUGIN_CI=1`, making `lint:dependencies` require the private
adversarial depth/cycle tests, ordinary brace-output checks and a
consumer-resolution check alongside the existing lints. Run the same checks
locally with `FF_PRIVATE_PLUGIN_CI=1 pnpm run lint`. The source-only public export
excludes the private tests; its ordinary lints still work without this flag.
The audit command remains unchanged and still
checks registry dependencies. Restore an upstream package when an upstream fix
is available, after running these regression and lint checks against it.
