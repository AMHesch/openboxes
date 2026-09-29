import { expect, type Page } from '@playwright/test';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';

export const testResultsDirectory = path.join(__dirname, 'test-results');

export async function takeNamedScreenshot(page: Page, fileName: string): Promise<void> {
  await fs.mkdir(testResultsDirectory, { recursive: true });
  await page.screenshot({
    path: path.join(testResultsDirectory, fileName),
    fullPage: true,
  });
}

export async function signInAndSelectMainWarehouse(
  page: Page,
  screenshotPrefix: string,
): Promise<void> {
  await page.goto('auth/login');
  await page.locator('#username').fill(process.env.OB_USER ?? 'admin');
  await page.locator('#password').fill(process.env.OB_PASSWORD ?? 'password');
  await page.locator('#loginButton').click();

  await expect(page.locator('[data-testid="location-chooser-modal"]')).toBeVisible({
    timeout: 120_000,
  });
  await takeNamedScreenshot(page, `${screenshotPrefix}-01-login.png`);

  await page.getByRole('link', { name: /Main Warehouse$/i }).click();
  await expect(page.getByRole('menuitem', { name: 'Dashboard' })).toBeVisible({
    timeout: 120_000,
  });
  await expect(page.getByRole('button', { name: 'location-chooser' })).toContainText(
    'Main Warehouse',
  );
  await takeNamedScreenshot(page, `${screenshotPrefix}-02-dashboard.png`);
}
