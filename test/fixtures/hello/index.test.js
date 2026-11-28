const test = require("node:test");
const assert = require("node:assert");
const { greet } = require("./index.js");

test("greet", () => {
  assert.strictEqual(greet("world"), "Hello, world!");
});
