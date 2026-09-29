import { expect, test } from '@playwright/test';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import {
  signInAndSelectMainWarehouse,
  takeNamedScreenshot,
  testResultsDirectory,
} from './support';

const DEMO_CATEGORY_NAME = 'DEMO Journey';

test.describe.configure({ mode: 'serial' });

test('create product and receive stock', async ({ page }) => {
  const runId = process.env.RUN_ID ?? Date.now().toString();
  const productName = `DEMO Widget ${runId}`;
  const lotNumber = `LOT-${runId}`;
  const screenshotPrefix = `${(process.env.PW_RUN_LABEL ?? new Date().toISOString())
    .replace(/[^a-zA-Z0-9_-]/g, '-')}-${runId.replace(/[^a-zA-Z0-9_-]/g, '-')}`;

  await signInAndSelectMainWarehouse(page, screenshotPrefix);

  await page.goto('product/create');
  const categorySelect = page.locator('select[name="category.id"]');
  await expect(categorySelect).toHaveCount(1);
  let categories = await categorySelect.locator('option').evaluateAll((options) =>
    options
      .map((option) => ({
        value: (option as HTMLOptionElement).value,
        label: (option as HTMLOptionElement).label,
      }))
      .filter((option) => option.value && option.label),
  );

  if (categories.length === 0) {
    await page.goto('category/tree');
    const categoryAlreadyExists = await page.getByText(DEMO_CATEGORY_NAME, { exact: true }).count();
    if (categoryAlreadyExists === 0) {
      await page.goto('category/create');
      await page.locator('input[name="name"]').fill(DEMO_CATEGORY_NAME);
      await page.getByRole('button', { name: /^Create$/ }).click();
    }

    await page.goto('product/create');
    categories = await page.locator('select[name="category.id"] option').evaluateAll((options) =>
      options
        .map((option) => ({
          value: (option as HTMLOptionElement).value,
          label: (option as HTMLOptionElement).label,
        }))
        .filter((option) => option.value && option.label),
    );
  }

  expect(categories.length, 'product creation requires an assignable category').toBeGreaterThan(0);
  const categoryWidget = page.locator('#categoryLabel').locator('xpath=ancestor::tr')
    .locator('.chosen-container');
  await categoryWidget.locator('.chosen-single').click();
  await categoryWidget.locator('.chosen-results li.active-result')
    .filter({ hasText: categories[0].label })
    .click();
  await page.getByRole('textbox', { name: /Product title/ }).fill(productName);
  await page.locator('#productForm').getByRole('button', { name: /Save/i }).click();

  const productIdField = page.locator('#productForm input[name="id"]');
  await expect(productIdField).not.toHaveValue('', { timeout: 120_000 });
  await expect(page.getByRole('alert')).toHaveCount(0);
  const productId = await productIdField.inputValue();
  const productCode = await page.locator('#productCode').inputValue();
  expect(productCode, 'the application should generate a product code').toBeTruthy();
  await takeNamedScreenshot(page, `${screenshotPrefix}-03-product-created.png`);

  await page.locator('.summary-actions .button-group')
    .getByRole('link', { name: /Show stock/i })
    .click();
  await expect(page).toHaveURL(/inventoryItem\/showStockCard/, { timeout: 120_000 });
  await page.getByRole('link', { name: /Record Stock/i }).click();
  await expect(page.locator('#saveInventoryItem')).toBeVisible({ timeout: 120_000 });
  await expect(page.locator('input.newQuantity').first()).toBeVisible();
  await page.locator('input.lotNumber').first().fill(lotNumber);
  await page.locator('input.newQuantity').first().fill('25');
  await page.locator('#saveInventoryItem').click();

  await expect(page).toHaveURL(/inventoryItem\/showStockCard/, { timeout: 120_000 });
  await expect(page.locator('#totalQuantity')).toHaveText('25', { timeout: 120_000 });
  await takeNamedScreenshot(page, `${screenshotPrefix}-04-stock-recorded.png`);
  await takeNamedScreenshot(page, `${screenshotPrefix}-05-stock-card-qoh-25.png`);

  const stockCard = new URL(page.url());
  await fs.mkdir(testResultsDirectory, { recursive: true });
  await fs.writeFile(
    path.join(testResultsDirectory, 'journey-state.json'),
    `${JSON.stringify({
      productCode,
      productUrl: `${stockCard.pathname}${stockCard.search}`,
      productId,
      productName,
      runId,
    }, null, 2)}\n`,
  );
});
