// collectors/example-web-v1/src/modules/collection/cli.ts
function run(args) {
  if (args.length === 1 && args[0] === "--help") {
    console.log(
      "example-web-v1: bootstrap example only. No source, network, database or collection commands are implemented."
    );
    return 0;
  }
  console.error("example-web-v1 is a bootstrap example; only --help is available.");
  return 1;
}

// collectors/example-web-v1/src/main.ts
process.exitCode = run(process.argv.slice(2));
