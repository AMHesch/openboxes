import { defineConfig } from '@playwright/test';
import * as path from 'node:path';

const baseURL = new URL(process.env.BASE_URL ?? 'http://localhost:8080/openboxes');
if (!baseURL.pathname.endsWith('/')) {
  baseURL.pathname += '/';
}

const runLabel = (process.env.PW_RUN_LABEL ?? new Date().toISOString())
  .replace(/[^a-zA-Z0-9_-]/g, '-');

export default defineConfig({
  testDir: '.',
  testMatch: ['journey.spec.ts', 'verify.spec.ts'],
  fullyParallel: false,
  workers: 1,
  maxFailures: 1,
  retries: 0,
  timeout: 180_000,
  expect: {
    timeout: 20_000,
  },
  reporter: [
    ['list'],
    ['html', {
      outputFolder: path.join('test-results', 'html-report', runLabel),
      open: 'never',
    }],
  ],
  outputDir: path.join('test-results', 'playwright', runLabel),
  use: {
    baseURL: baseURL.toString(),
    browserName: 'chromium',
    actionTimeout: 45_000,
    navigationTimeout: 120_000,
    screenshot: 'on',
    video: 'on',
    trace: 'on',
  },
});
