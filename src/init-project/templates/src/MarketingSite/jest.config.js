// Jest config for the MarketingSite SPA. Angular itself is pinned ONCE in the root
// package.json; this file only wires jest-preset-angular + the 100% coverage gate
// (docs/tdd.md). The preset already compiles specs with tsconfig.spec.json.
// main.ts / *.config.ts / *.routes.ts are bootstrap glue, excluded per the tdd.md
// Angular coverage-exclusion policy.
const presetConfig = require('jest-preset-angular/presets').createCjsPreset();

/** @type {import('jest').Config} */
module.exports = {
  ...presetConfig,
  rootDir: __dirname,
  setupFilesAfterEnv: ['<rootDir>/setup-jest.ts'],
  testMatch: ['<rootDir>/src/**/*.spec.ts'],
  collectCoverageFrom: [
    'src/**/*.ts',
    '!src/main.ts',
    '!src/**/*.config.ts',
    '!src/**/*.routes.ts',
    '!src/**/*.spec.ts',
  ],
  coverageThreshold: {
    global: { branches: 100, functions: 100, lines: 100, statements: 100 },
  },
};
