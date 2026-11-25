import { expect, test } from 'vitest'
import { baseContribution, cumulativeMomentum, delayContribution } from './index'

test('accumulates signed ledger entries from the starting value', () => {
  expect(cumulativeMomentum([3, 1.8, -2, 2.7, 4, -2, 5])).toBeCloseTo(12.5)
  expect(cumulativeMomentum([-3], 25)).toBe(22)
})


test('uses the approved base and delay formulas', () => {
  expect(baseContribution(100)).toBe(1)
  expect(baseContribution(99)).toBeCloseTo(-0.01)
  expect(baseContribution(80) + delayContribution(6)).toBeCloseTo(-0.50)
  expect(baseContribution(0) + delayContribution(10)).toBeCloseTo(-1.50)
  expect(delayContribution(24 * 30)).toBeCloseTo(-36)
})
