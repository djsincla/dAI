import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Each test resets the schema, so files must not run against it in parallel.
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
})
