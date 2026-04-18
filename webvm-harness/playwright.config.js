import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  testMatch: /.*\.e2e\.test\.js/,
  fullyParallel: false,
  reporter: "list",
  use: {
    headless: true,
  },
});
