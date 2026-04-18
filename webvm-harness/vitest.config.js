import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["tests/**/*.test.js"],
    exclude: ["tests/**/*.e2e.test.js", "node_modules/**"],
    environment: "node",
  },
});
