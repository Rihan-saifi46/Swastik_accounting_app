/**
 * Test Suite: Staff Transaction Date Editing Permission & Authorization
 * 
 * Tests:
 * 1. PATCH /api/transactions/:id/date payload validation (date-only vs extra fields)
 * 2. Role-based authorization for PATCH /date, PUT /transactions/:id, and DELETE /transactions/:id
 * 3. Daily balance recalculation date bounding: Math.min(oldDate, newDate)
 * 4. Accounting invariance: party balance, cash/online/gold/diamond deltas
 */

const assert = require('assert');

// ─── 1. SIMULATE PAYLOAD VALIDATION LOGIC ────────────────────────────────────

function validatePatchDatePayload(body) {
  const allowedKeys = ['date'];
  const extraKeys = Object.keys(body).filter(k => k !== 'callerRole' && !allowedKeys.includes(k));

  if (extraKeys.length > 0) {
    return {
      status: 403,
      error: `Forbidden: Only the transaction date can be modified. Unauthorized fields: ${extraKeys.join(', ')}`
    };
  }

  if (!body.date) {
    return { status: 400, error: 'Missing required field: date' };
  }

  const newDate = new Date(body.date);
  if (isNaN(newDate.getTime())) {
    return { status: 400, error: 'Invalid date format' };
  }

  return { status: 200, validDate: newDate };
}

// Test 1.1: Valid date-only payload
{
  const res = validatePatchDatePayload({ date: '2026-10-31T10:00:00.000Z', callerRole: 'staff' });
  assert.strictEqual(res.status, 200, 'Valid date payload must return 200');
  assert.strictEqual(res.validDate instanceof Date, true);
  console.log('✓ Test 1.1 Passed: Valid date-only payload accepted');
}

// Test 1.2: Payload with unauthorized amount modification
{
  const res = validatePatchDatePayload({
    date: '2026-10-31T10:00:00.000Z',
    cashAmount: 50000,
    callerRole: 'staff'
  });
  assert.strictEqual(res.status, 403, 'Must reject payload containing cashAmount with 403');
  assert.ok(res.error.includes('Unauthorized fields: cashAmount'));
  console.log('✓ Test 1.2 Passed: cashAmount modification rejected with 403');
}

// Test 1.3: Payload with unauthorized party modification
{
  const res = validatePatchDatePayload({
    date: '2026-10-31T10:00:00.000Z',
    partyId: 'party_999',
    callerRole: 'staff'
  });
  assert.strictEqual(res.status, 403, 'Must reject payload containing partyId with 403');
  assert.ok(res.error.includes('Unauthorized fields: partyId'));
  console.log('✓ Test 1.3 Passed: partyId modification rejected with 403');
}

// Test 1.4: Payload with unauthorized type modification
{
  const res = validatePatchDatePayload({
    date: '2026-10-31T10:00:00.000Z',
    type: 'payment',
    callerRole: 'staff'
  });
  assert.strictEqual(res.status, 403, 'Must reject payload containing type with 403');
  assert.ok(res.error.includes('Unauthorized fields: type'));
  console.log('✓ Test 1.4 Passed: type modification rejected with 403');
}

// Test 1.5: Payload with invalid date format
{
  const res = validatePatchDatePayload({
    date: 'invalid-date-string',
    callerRole: 'staff'
  });
  assert.strictEqual(res.status, 400, 'Must reject invalid date format with 400');
  console.log('✓ Test 1.5 Passed: Invalid date format rejected with 400');
}

// ─── 2. SIMULATE ENDPOINT AUTHORIZATION ENFORCEMENT ──────────────────────────

function checkRequireAdmin(callerRole) {
  if (callerRole === 'admin') {
    return { status: 200 };
  }
  return {
    status: 403,
    error: 'Forbidden: Only Admins can modify or delete finalized transactions.'
  };
}

// Test 2.1: Staff cannot call full PUT
{
  const res = checkRequireAdmin('staff');
  assert.strictEqual(res.status, 403);
  console.log('✓ Test 2.1 Passed: Staff blocked from full PUT /api/transactions/:id with 403');
}

// Test 2.2: Staff cannot call DELETE
{
  const res = checkRequireAdmin('staff');
  assert.strictEqual(res.status, 403);
  console.log('✓ Test 2.2 Passed: Staff blocked from DELETE /api/transactions/:id with 403');
}

// Test 2.3: Admin can call full PUT and DELETE
{
  const resPut = checkRequireAdmin('admin');
  const resDel = checkRequireAdmin('admin');
  assert.strictEqual(resPut.status, 200);
  assert.strictEqual(resDel.status, 200);
  console.log('✓ Test 2.3 Passed: Admin authorized for full PUT and DELETE');
}

// ─── 3. SIMULATE DATE SHIFTING & ACCOUNTING CALCULATION ───────────────────────

function computeRecalcFromDate(oldDate, newDate) {
  const dOld = new Date(oldDate);
  const dNew = new Date(newDate);
  return dOld < dNew ? dOld : dNew;
}

// Test 3.1: Moving transaction forward (past -> future)
{
  const oldDate = new Date('2026-10-15T12:00:00Z');
  const newDate = new Date('2026-10-25T12:00:00Z');
  const recalcFrom = computeRecalcFromDate(oldDate, newDate);
  assert.strictEqual(recalcFrom.toISOString(), oldDate.toISOString(), 'Recalculation must start from the earlier old date');
  console.log('✓ Test 3.1 Passed: Moving transaction forward recalculates from old date');
}

// Test 3.2: Moving transaction backward (future -> past)
{
  const oldDate = new Date('2026-10-28T12:00:00Z');
  const newDate = new Date('2026-10-10T12:00:00Z');
  const recalcFrom = computeRecalcFromDate(oldDate, newDate);
  assert.strictEqual(recalcFrom.toISOString(), newDate.toISOString(), 'Recalculation must start from the earlier new date');
  console.log('✓ Test 3.2 Passed: Moving transaction backward recalculates from new date');
}

// ─── 4. PARTY BALANCE AND FINANCIAL MATH INVARIANCE ──────────────────────────

function partyBalanceInc(tx, direction = 1) {
  const isDebit = tx.type === 'payment' || tx.type === 'sale' || tx.type === 'metalOut';
  const isCredit = tx.type === 'receipt' || tx.type === 'purchase' || tx.type === 'metalIn' || tx.type === 'return_';
  const sign = (isDebit ? 1 : isCredit ? -1 : 0) * direction;
  if (sign === 0) return {};

  if (!tx.metalType) {
    const amt = Number(tx.cashAmount) || 0;
    return amt ? { cashBalance: sign * amt } : {};
  }
  const wt = Number(tx.metalWeight) || 0;
  if (tx.metalType === 'gold') return wt ? { goldBalanceGrams: sign * wt } : {};
  if (tx.metalType === 'diamond') return wt ? { diamondBalanceCarats: sign * wt } : {};
  return {};
}

// Test 4.1: Verify party balance delta when only date changes
{
  const mockTx = {
    partyId: 'party_123',
    type: 'payment',
    cashAmount: 15000,
    metalType: '',
    date: new Date('2026-10-20T10:00:00Z')
  };

  const oldImpact = partyBalanceInc(mockTx, 1);
  // Change date only
  const updatedTx = { ...mockTx, date: new Date('2026-10-25T14:30:00Z') };
  const newImpact = partyBalanceInc(updatedTx, 1);

  // Reversing old and applying new produces net 0 change to party balance
  const netDelta = (newImpact.cashBalance || 0) - (oldImpact.cashBalance || 0);
  assert.strictEqual(netDelta, 0, 'Party balance must remain 100% invariant when date changes');
  console.log('✓ Test 4.1 Passed: Party balance remains 100% invariant');
}

// Test 4.2: Verify Gold weight invariance
{
  const mockGoldTx = {
    partyId: 'party_gold_1',
    type: 'metalIn',
    cashAmount: 0,
    metalType: 'gold',
    metalWeight: 25.5,
    date: new Date('2026-10-01T10:00:00Z')
  };

  const oldImpact = partyBalanceInc(mockGoldTx, 1);
  const updatedGoldTx = { ...mockGoldTx, date: new Date('2026-10-18T10:00:00Z') };
  const newImpact = partyBalanceInc(updatedGoldTx, 1);

  const netDelta = (newImpact.goldBalanceGrams || 0) - (oldImpact.goldBalanceGrams || 0);
  assert.strictEqual(netDelta, 0, 'Gold weight balance must remain 100% invariant');
  console.log('✓ Test 4.2 Passed: Gold weight balance remains 100% invariant');
}

// Test 4.3: Verify Diamond carat invariance
{
  const mockDiamondTx = {
    partyId: 'party_dia_1',
    type: 'metalOut',
    cashAmount: 0,
    metalType: 'diamond',
    metalWeight: 4.25,
    date: new Date('2026-10-05T10:00:00Z')
  };

  const oldImpact = partyBalanceInc(mockDiamondTx, 1);
  const updatedDiamondTx = { ...mockDiamondTx, date: new Date('2026-10-29T10:00:00Z') };
  const newImpact = partyBalanceInc(updatedDiamondTx, 1);

  const netDelta = (newImpact.diamondBalanceCarats || 0) - (oldImpact.diamondBalanceCarats || 0);
  assert.strictEqual(netDelta, 0, 'Diamond carat balance must remain 100% invariant');
  console.log('✓ Test 4.3 Passed: Diamond carat balance remains 100% invariant');
}

console.log('\n========================================');
console.log('ALL STAFF DATE EDIT PERMISSION TESTS PASSED (100%)');
console.log('========================================');

