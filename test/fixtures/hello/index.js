const pc = require("picocolors");

function greet(name) {
  return `Hello, ${name}!`;
}

if (require.main === module) {
  console.log(pc.bold(greet("world")));
}

module.exports = { greet };
