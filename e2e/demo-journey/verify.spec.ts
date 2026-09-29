import { expect, test } from '@playwright/test';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import {
  signInAndSelectMainWarehouse,
  takeNamedScreenshot,
  testResultsDirectory,
} from './support';

type JourneyState = {
  productCode?: string;
  productName?: string;
  runId?: string;
};

test.describe.configure({ mode: 'serial' });

test('data persisted', async ({ page }) => {
  let journeyState: JourneyState | undefined;
  if (!process.env.PRODUCT_CODE) {
    const statePath = path.join(testResultsDirectory, 'journey-state.json');
    try {
      journeyState = JSON.parse(await fs.readFile(statePath, 'utf8')) as JourneyState;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        throw error;
      }
    }
  }

  const productCode = process.env.PRODUCT_CODE ?? journeyState?.productCode;
  expect(productCode, 'set PRODUCT_CODE or run journey.spec.ts first').toBeTruthy();
  const productName = process.env.PRODUCT_CODE ? undefined : journeyState?.productName;
  const screenshotPrefix = (process.env.PW_RUN_LABEL ?? new Date().toISOString())
    .replace(/[^a-zA-Z0-9_-]/g, '-');

  await signInAndSelectMainWarehouse(page, screenshotPrefix);
  await page.goto('inventory/browse');
  const inventorySearch = page.locator('.filters form');
  await inventorySearch.getByRole('textbox', { name: /Search by product name/ }).fill(productCode!);
  await inventorySearch.getByRole('button', { name: /Search/i }).click();

  const searchText = productName ?? productCode!;
  const resultLink = page.getByRole('link', {
    name: new RegExp(searchText.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'),
  }).first();
  await expect(resultLink).toBeVisible({ timeout: 120_000 });
  await resultLink.click();

  await expect(page).toHaveURL(/inventoryItem\/showStockCard/, { timeout: 120_000 });
  await expect(page.locator('#totalQuantity')).toHaveText('25', { timeout: 120_000 });
  await takeNamedScreenshot(page, `${screenshotPrefix}-verify-stock-card-qoh-25.png`);
});
