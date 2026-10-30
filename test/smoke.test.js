const test = require("node:test")
const assert = require("node:assert/strict")
const _ = require("lodash")

test("lodash chunk works", () => {
    assert.deepEqual(_.chunk([1, 2, 3, 4], 2), [[1, 2], [3, 4]])
})
