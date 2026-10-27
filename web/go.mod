// Marks web/ as its own (empty) module so `go ... ./...` from the repo root
// skips it. Some npm packages ship Go sources under node_modules, which
// otherwise get built, tested, and linted as part of this project.
module web
