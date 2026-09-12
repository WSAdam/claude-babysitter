import { greet } from "./greet.ts";

Deno.test("greet says hello by name", () => {
  if (greet("Adam") !== "Hello, Adam!") throw new Error(greet("Adam"));
});
