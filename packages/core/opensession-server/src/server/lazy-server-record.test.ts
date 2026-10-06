import { expect, test } from "bun:test";
import { lazyServerRecord } from "./inprocess-mcp";

test("builds each entry once, on first read, and only that entry", () => {
  const built: string[] = [];
  const make = (name: string) => () => {
    built.push(name);
    return { type: "sdk", name };
  };
  const eager = { type: "sdk", name: "eager" };
  const servers = lazyServerRecord({ a: make("a"), b: make("b"), eager });

  expect(Object.keys(servers)).toEqual(["a", "b", "eager"]);
  expect("b" in servers).toBe(true);
  expect(built).toEqual([]);

  const a = servers.a;
  expect(servers.a).toBe(a);
  expect(built).toEqual(["a"]);
  expect(servers.eager).toBe(eager);

  expect({ ...servers }).toEqual({
    a: { type: "sdk", name: "a" },
    b: { type: "sdk", name: "b" },
    eager,
  });
  expect(built).toEqual(["a", "b"]);
});

test("entries can be replaced and deleted like plain properties", () => {
  const servers = lazyServerRecord({ a: () => "built", b: () => "built" });
  servers.a = "replaced";
  delete servers.b;
  servers.c = "added";
  expect(servers).toEqual({ a: "replaced", c: "added" });
});
